#include "Vfriscv_soc.h"
#include "verilated.h"

#include <cstdio>
#include <stdexcept>
#include <vector>

#include "elf_loader.hpp"
#include "jtag.hpp"

namespace {

constexpr uint32_t SCRATCH_ADDRESS = 0x40000000;
constexpr uint32_t PARKED = 1;
constexpr uint32_t SRAM_SIZE = 0x4000;
constexpr uint16_t RISCV_MACHINE = 243;
constexpr uint64_t RUN_CYCLES = 2000;

std::vector<uint8_t> word_bytes(uint32_t value) {
    return {
        uint8_t(value),
        uint8_t(value >> 8),
        uint8_t(value >> 16),
        uint8_t(value >> 24),
    };
}

uint32_t read_word(Jtag& jtag, uint32_t address) {
    std::vector<uint8_t> data = jtag.read_memory(address, 4);
    return uint32_t(data[0]) |
           (uint32_t(data[1]) << 8) |
           (uint32_t(data[2]) << 16) |
           (uint32_t(data[3]) << 24);
}

void wait_for_boot_rom(Jtag& jtag) {
    for (unsigned i = 0; i < 1000; ++i) {
        if (read_word(jtag, SCRATCH_ADDRESS) == PARKED) {
            return;
        }
        jtag.run_cycles(8);
    }
    throw std::runtime_error("boot ROM did not park");
}

void validate(const ElfImage& image) {
    if (image.machine != RISCV_MACHINE) {
        throw std::runtime_error("ELF is not for RISC-V");
    }

    bool entry_ok = false;
    for (const ElfSegment& segment : image.segments) {
        uint64_t end = uint64_t(segment.address) + segment.data.size();
        if (end > SRAM_SIZE) {
            throw std::runtime_error("ELF segment is outside SRAM");
        }

        if (segment.executable && image.entry >= segment.address &&
            image.entry < end) {
            entry_ok = true;
        }
    }

    if ((image.entry & 3) != 0 || image.entry == PARKED || !entry_ok) {
        throw std::runtime_error("invalid ELF entry point");
    }
}

void flash(Jtag& jtag, const char* path) {
    ElfImage image = read_elf(path);
    validate(image);

    jtag.reset_soc();
    wait_for_boot_rom(jtag);

    for (const ElfSegment& segment : image.segments) {
        jtag.write_memory(segment.address, segment.data);
    }

    jtag.write_memory(SCRATCH_ADDRESS, word_bytes(image.entry));
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    if (argc != 2) {
        std::fprintf(stderr, "usage: %s <program.elf>\n", argv[0]);
        return 1;
    }

    try {
        Vfriscv_soc top;
        top.i_clk = 0;
        top.i_rstn = 0;
        top.i_uart_rx = 1;
        top.i_jtag_tck = 0;
        top.i_jtag_tms = 1;
        top.i_jtag_tdi = 0;
        top.eval();

        Jtag jtag(top);
        jtag.run_cycles(20);
        top.i_rstn = 1;
        jtag.run_cycles(20);
        jtag.initialize();

        flash(jtag, argv[1]);
        jtag.run_cycles(RUN_CYCLES);

        top.final();
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "JTAG simulation failed: %s\n", error.what());
        return 1;
    }
}

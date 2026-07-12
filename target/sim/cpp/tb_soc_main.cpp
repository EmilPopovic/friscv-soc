#include "Vfriscv_soc.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <vector>

#include "elf_loader.hpp"
#include "jtag.hpp"
#include "remote_bitbang.hpp"

namespace {

constexpr uint32_t SCRATCH_ADDRESS = 0x40000000;
constexpr uint32_t PARKED = 1;
constexpr uint32_t SRAM_SIZE = 0x4000;
constexpr uint16_t RISCV_MACHINE = 243;
constexpr uint64_t RUN_CYCLES = 2000;

uint32_t parse_u32(const char* text) {
    char* end = nullptr;
    unsigned long value = std::strtoul(text, &end, 0);

    if (!text[0] || *end || value > std::numeric_limits<uint32_t>::max()) {
        throw std::runtime_error("invalid number");
    }

    return uint32_t(value);
}

uint8_t parse_byte(const char* text) {
    char* end = nullptr;
    unsigned long value = std::strtoul(text, &end, 16);

    if (!text[0] || *end || value > std::numeric_limits<uint8_t>::max()) {
        throw std::runtime_error("invalid byte");
    }

    return uint8_t(value);
}

uint16_t parse_port(const char* text) {
    uint32_t port = parse_u32(text);

    if (port == 0 || port > std::numeric_limits<uint16_t>::max()) {
        throw std::runtime_error("invalid port");
    }

    return uint16_t(port);
}

void check_range(uint32_t address, size_t size) {
    uint64_t end = uint64_t(address) + size;
    uint64_t limit = uint64_t(std::numeric_limits<uint32_t>::max()) + 1;

    if (end > limit) {
        throw std::runtime_error("memory range wraps around");
    }
}

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

void park(Jtag& jtag) {
    jtag.reset_soc();
    wait_for_boot_rom(jtag);
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

void load_command(Jtag& jtag, const char* path) {
    ElfImage image = read_elf(path);
    validate(image);
    park(jtag);

    for (const ElfSegment& segment : image.segments) {
        jtag.write_memory(segment.address, segment.data);
    }

    jtag.write_memory(SCRATCH_ADDRESS, word_bytes(image.entry));
    jtag.run_cycles(RUN_CYCLES);
}

void print_memory(uint32_t address, const std::vector<uint8_t>& data) {
    for (size_t offset = 0; offset < data.size(); ++offset) {
        if ((offset & 15) == 0) {
            std::printf("%08x:", address + uint32_t(offset));
        }

        std::printf(" %02x", data[offset]);

        if ((offset & 15) == 15 || offset + 1 == data.size()) {
            std::printf("\n");
        }
    }
}

void read_command(Jtag& jtag, const char* address_text, const char* size_text) {
    uint32_t address = parse_u32(address_text);
    uint32_t size = parse_u32(size_text);

    check_range(address, size);
    park(jtag);

    print_memory(address, jtag.read_memory(address, size));
}

void write_command(Jtag& jtag, int argc, char** argv) {
    uint32_t address = parse_u32(argv[2]);
    std::vector<uint8_t> data;

    data.reserve(size_t(argc - 3));

    for (int i = 3; i < argc; ++i) {
        data.push_back(parse_byte(argv[i]));
    }

    check_range(address, data.size());
    park(jtag);
    jtag.write_memory(address, data);

    std::printf("wrote %zu bytes at %08x\n", data.size(), address);
}

bool server_command(int argc, char** argv) {
    return (argc == 2 || argc == 3) && !std::strcmp(argv[1], "server");
}

bool valid_command(int argc, char** argv) {
    return server_command(argc, argv) ||
           (argc == 3 && !std::strcmp(argv[1], "load")) ||
           (argc == 4 && !std::strcmp(argv[1], "read")) ||
           (argc >= 4 && !std::strcmp(argv[1], "write"));
}

void execute_command(Jtag& jtag, int argc, char** argv) {
    if (!std::strcmp(argv[1], "load")) {
        load_command(jtag, argv[2]);
        return;
    }

    if (!std::strcmp(argv[1], "read")) {
        read_command(jtag, argv[2], argv[3]);
        return;
    }

    write_command(jtag, argc, argv);
}

void print_usage(const char* program) {
    std::fprintf(stderr,
                 "usage:\n"
                 "  %s load <program.elf>\n"
                 "  %s read <address> <size>\n"
                 "  %s write <address> <byte> [byte ...]\n"
                 "  %s server [port]\n",
                 program, program, program, program);
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    if (!valid_command(argc, argv)) {
        print_usage(argv[0]);
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

        if (server_command(argc, argv)) {
            uint16_t port = argc == 3 ? parse_port(argv[2])
                                      : RemoteBitbang::DEFAULT_PORT;
            RemoteBitbang(top).serve(port);
        } else {
            jtag.initialize();

            execute_command(jtag, argc, argv);
        }

        top.final();
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "JTAG simulation failed: %s\n", error.what());
        return 1;
    }
}

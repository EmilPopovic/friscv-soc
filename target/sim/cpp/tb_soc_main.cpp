// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
// Emil Popović <mail@emilpopovic.me>

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
#include "soc_memory.hpp"
#include "soc_testbench.hpp"

namespace {

#ifndef VERNII_SRAM_BASE
#define VERNII_SRAM_BASE 0
#endif

#ifndef VERNII_SRAM_SIZE_BYTES
#define VERNII_SRAM_SIZE_BYTES 0x2000
#endif

constexpr uint32_t MEM_BASE = 0x80000000;
constexpr uint32_t UART0_BASE = 0x03010000;
constexpr uint32_t SCB_LLCSEL = 0x0300000C;
constexpr uint32_t HYPER_CFG_BASE = 0x04010000;
constexpr uint32_t SCRATCH_ADDRESS = 0x03000000;
constexpr uint32_t PARKED = 1;
constexpr uint32_t PASS_VALUE = 0xaabbccdd;
constexpr uint32_t SRAM_BASE = VERNII_SOC_SRAM_BASE;
constexpr uint32_t SRAM_SIZE = VERNII_SOC_SRAM_SIZE_BYTES;
constexpr uint16_t RISCV_MACHINE = 243;
constexpr uint64_t RUN_CYCLES = 2000;
constexpr uint64_t TEST_CYCLES = 10000000;

// The ROM reads whole segments and takes the total from the stage's first word
constexpr size_t ZSBL_STAGE_BYTES = 0x1000;
// UART_DIV in zsbl.S, fixed in mask ROM
constexpr uint32_t ZSBL_UART_DIV = 27;
// The stage checks the block from here on, so a partial transfer cannot pass
constexpr size_t STAGE_PATTERN_START = 1024;

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

void wait_for_boot_rom(SocTestbench& testbench, Jtag& jtag) {
    for (unsigned i = 0; i < 1000; ++i) {
        if (read_word(jtag, SCRATCH_ADDRESS) == PARKED) {
            return;
        }

        testbench.run_cycles(8);
    }

    throw std::runtime_error("boot ROM did not park");
}

void park(SocTestbench& testbench, Jtag& jtag) {
    jtag.reset_soc();
    wait_for_boot_rom(testbench, jtag);
}

// The arch-test build relocates the SRAM over MEM_BASE, so external means
// outside the SRAM, not simply at or above MEM_BASE
bool is_external(uint32_t address) {
    return address < SRAM_BASE || address >= uint64_t(SRAM_BASE) + SRAM_SIZE;
}

void validate(const ElfImage& image) {
    if (image.machine != RISCV_MACHINE) {
        throw std::runtime_error("ELF is not for RISC-V");
    }

    bool entry_ok = false;
    bool external = is_external(image.entry);

    for (const ElfSegment& segment : image.segments) {
        uint64_t start = segment.address;
        uint64_t end = uint64_t(segment.address) + segment.data.size();

        if (external) {
            if (start < MEM_BASE) {
                throw std::runtime_error("ELF mixes external and SRAM segments");
            }
        } else if (start < SRAM_BASE || end > uint64_t(SRAM_BASE) + SRAM_SIZE) {
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

// VERNII_HB_CFG="reg:value[,...]" writes the HyperBus config before the program
// runs, so a sweep needs no rebuild
void apply_hyperbus_config(Jtag& jtag) {
    const char* spec = std::getenv("VERNII_HB_CFG");

    if (spec == nullptr) {
        return;
    }

    while (*spec != '\0') {
        char* end = nullptr;
        unsigned long index = std::strtoul(spec, &end, 0);

        if (end == spec || *end != ':') {
            throw std::runtime_error("VERNII_HB_CFG wants reg:value pairs");
        }

        spec = end + 1;
        unsigned long value = std::strtoul(spec, &end, 0);

        if (end == spec) {
            throw std::runtime_error("VERNII_HB_CFG wants reg:value pairs");
        }

        jtag.write_memory(HYPER_CFG_BASE + uint32_t(index) * 4,
                          word_bytes(uint32_t(value)));
        std::fprintf(stderr, "hyperbus cfg[%lu] = %lu\n", index, value);

        spec = (*end == ',') ? end + 1 : end;
    }
}

// VERNII_LLCSEL marks ways as cache, so an image linked into the cached region
// can run from there
void apply_cache_config(Jtag& jtag) {
    const char* mask = std::getenv("VERNII_LLCSEL");

    if (mask == nullptr) {
        return;
    }

    jtag.write_memory(SCB_LLCSEL, word_bytes(uint32_t(std::strtoul(mask, nullptr, 0))));
}

// VERNII_UART_DIV sets the 16550 divisor for software that expects a boot stub
// to have done it, and gives the monitor its bit period
void apply_uart_config(SocTestbench& testbench, Jtag& jtag) {
    const char* div = std::getenv("VERNII_UART_DIV");

    if (div == nullptr) {
        return;
    }

    uint32_t divisor = uint32_t(std::strtoul(div, nullptr, 0));

    jtag.write_memory(UART0_BASE + 0x0c, word_bytes(0x80));      // DLAB
    jtag.write_memory(UART0_BASE + 0x00, word_bytes(divisor & 0xFF));
    jtag.write_memory(UART0_BASE + 0x04, word_bytes(divisor >> 8));
    jtag.write_memory(UART0_BASE + 0x0c, word_bytes(0x03));      // 8N1

    testbench.uart().set_divisor(divisor);
}

std::vector<uint8_t> read_file(const char* path) {
    std::FILE* file = std::fopen(path, "rb");

    if (file == nullptr) {
        throw std::runtime_error("cannot open the flash image");
    }

    std::vector<uint8_t> data;
    uint8_t chunk[4096];
    size_t read = 0;

    while ((read = std::fread(chunk, 1, sizeof(chunk), file)) > 0) {
        data.insert(data.end(), chunk, chunk + read);
    }

    std::fclose(file);
    return data;
}

// VERNII_FLASH=<file> fills the flash for programs that drive it themselves
void apply_flash_image(SocTestbench& testbench) {
    const char* path = std::getenv("VERNII_FLASH");

    if (path == nullptr) {
        return;
    }

    std::vector<uint8_t> data = read_file(path);
    testbench.flash().preload(0, data);
    std::fprintf(stderr, "flash image %s: %zu bytes\n", path, data.size());
}

// VERNII_SD_IMAGE=<file> fills the card for a stage that boots from it
void apply_sd_image(SocTestbench& testbench) {
    const char* path = std::getenv("VERNII_SD_IMAGE");

    if (path == nullptr) {
        return;
    }

    std::vector<uint8_t> data = read_file(path);
    testbench.sd().preload(0, data);
    std::fprintf(stderr, "sd image %s: %zu bytes\n", path, data.size());
}

ElfImage prepare_image(SocTestbench& testbench, Jtag& jtag,
                       const char* path) {
    ElfImage image = read_elf(path);
    validate(image);
    park(testbench, jtag);
    apply_hyperbus_config(jtag);
    apply_cache_config(jtag);
    apply_uart_config(testbench, jtag);
    apply_flash_image(testbench);
    apply_sd_image(testbench);

    return image;
}

void start_image(Jtag& jtag, uint32_t entry) {
    jtag.write_memory(SCRATCH_ADDRESS, word_bytes(entry));
}

void load_image(SocTestbench& testbench, Jtag& jtag, const char* path) {
    ElfImage image = prepare_image(testbench, jtag, path);

    for (const ElfSegment& segment : image.segments) {
        jtag.write_memory(segment.address, segment.data);
    }

    start_image(jtag, image.entry);
}

void load_command(SocTestbench& testbench, Jtag& jtag, const char* path) {
    load_image(testbench, jtag, path);
    testbench.run_cycles(RUN_CYCLES);
}

// image in the flash, boot select 1, nothing preloaded
int qspiboot_command(SocTestbench& testbench, Jtag& jtag, const char* path) {
    Dut& top = testbench.top();

    std::vector<uint8_t> image = read_file(path);
    testbench.flash().preload(0, image);
    std::fprintf(stderr, "flash image %s: %zu bytes\n", path, image.size());

    apply_sd_image(testbench);

    // the second stage sets the divisor, this is just for the decoder
    if (const char* div = std::getenv("VERNII_UART_DIV")) {
        testbench.uart().set_divisor(uint32_t(std::strtoul(div, nullptr, 0)));
    }

    dut::set_boot_sel(top, 1);
    testbench.reset();
    jtag.initialize();  // the reset above took the debug module with it

    uint64_t limit = TEST_CYCLES;

    if (const char* env = std::getenv("VERNII_TEST_CYCLES")) {
        limit = std::strtoull(env, nullptr, 0);
    }

    for (uint64_t cycle = 0; cycle < limit && !top.end_o; ++cycle) {
        testbench.run_cycles(1);
    }

    uint32_t result = read_word(jtag, SCRATCH_ADDRESS);
    unsigned long long cycles = testbench.cycles();

    if (top.end_o && result == PASS_VALUE) {
        std::fprintf(stderr, "PASS (%llu cycles)\n", cycles);
        return 0;
    }

    std::fprintf(stderr, "FAIL (scratch=0x%08x, %llu cycles)\n", result, cycles);
    return 1;
}

// Boot select 2: the ROM takes its first stage off the UART instead of flash
int uartboot_command(SocTestbench& testbench, Jtag& jtag, const char* path) {
    Dut& top = testbench.top();

    std::vector<uint8_t> stage = read_file(path);

    if (stage.size() > ZSBL_STAGE_BYTES) {
        std::fprintf(stderr, "stage %s is %zu bytes, the rom takes %zu\n",
                     path, stage.size(), ZSBL_STAGE_BYTES);
        return 1;
    }

    // Padded out the way mkflash.py does, with a known tail so a short or
    // garbled transfer cannot pass
    stage.resize(ZSBL_STAGE_BYTES, 0);

    for (size_t i = STAGE_PATTERN_START; i < ZSBL_STAGE_BYTES; ++i) {
        stage[i] = uint8_t(i * 7 + 0x5a);
    }

    uint32_t divisor = ZSBL_UART_DIV;

    if (const char* env = std::getenv("VERNII_UART_DIV")) {
        divisor = uint32_t(std::strtoul(env, nullptr, 0));
    }

    testbench.uart().set_divisor(divisor);
    testbench.uart_rx().set_divisor(divisor);

    // Model a host clock that does not match the chip's
    if (const char* env = std::getenv("VERNII_UART_BIT_CYCLES")) {
        testbench.uart_rx().set_bit_cycles(unsigned(std::strtoul(env, nullptr, 0)));
    }

    unsigned boot_sel = 2;

    if (const char* env = std::getenv("VERNII_BOOT_SEL")) {
        boot_sel = unsigned(std::strtoul(env, nullptr, 0));
    }

    dut::set_boot_sel(top, boot_sel);
    testbench.reset();
    jtag.initialize();  // the reset above took the debug module with it

    testbench.uart_rx().send(stage);
    std::fprintf(stderr, "uart stage %s: %zu bytes at divisor %u\n",
                 path, stage.size(), divisor);

    uint64_t limit = TEST_CYCLES;

    if (const char* env = std::getenv("VERNII_TEST_CYCLES")) {
        limit = std::strtoull(env, nullptr, 0);
    }

    for (uint64_t cycle = 0; cycle < limit && !top.end_o; ++cycle) {
        testbench.run_cycles(1);
    }

    // The rom's banner byte lands on stderr, keep it off the verdict line
    std::fputc('\n', stderr);

    uint32_t result = read_word(jtag, SCRATCH_ADDRESS);
    unsigned long long cycles = testbench.cycles();

    if (top.end_o && result == PASS_VALUE) {
        std::fprintf(stderr, "PASS (%llu cycles)\n", cycles);
        return 0;
    }

    std::fprintf(stderr, "FAIL (scratch=0x%08x, %llu cycles)\n", result, cycles);
    return 1;
}

int test_command(SocTestbench& testbench, Jtag& jtag, const char* path) {
    Dut& top = testbench.top();
    ElfImage image = prepare_image(testbench, jtag, path);

    // An image outside the SRAM belongs to the external memory
    if (is_external(image.entry)) {
        for (const ElfSegment& segment : image.segments) {
            testbench.ext_mem().preload(segment.address - MEM_BASE, segment.data);
        }
    } else {
        preload_sram(top, image, SRAM_BASE);
    }
    start_image(jtag, image.entry);

    uint64_t limit = TEST_CYCLES;

    if (const char* env = std::getenv("VERNII_TEST_CYCLES")) {
        limit = std::strtoull(env, nullptr, 0);
    }

    for (uint64_t cycle = 0; cycle < limit && !top.end_o; ++cycle) {
        testbench.run_cycles(1);
    }

    uint32_t result = read_word(jtag, SCRATCH_ADDRESS);

    // From reset, so the count does not shift with debug-module traffic
    unsigned long long cycles = testbench.cycles();

    if (top.end_o && result == PASS_VALUE) {
        std::fprintf(stderr, "PASS (%llu cycles)\n", cycles);
        return 0;
    }

    std::fprintf(stderr, "FAIL (scratch=0x%08x, %llu cycles)\n", result, cycles);
    return 1;
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

void read_command(SocTestbench& testbench, Jtag& jtag,
                  const char* address_text, const char* size_text) {
    uint32_t address = parse_u32(address_text);
    uint32_t size = parse_u32(size_text);

    check_range(address, size);
    park(testbench, jtag);

    print_memory(address, jtag.read_memory(address, size));
}

void write_command(SocTestbench& testbench, Jtag& jtag,
                   int argc, char** argv) {
    uint32_t address = parse_u32(argv[2]);
    std::vector<uint8_t> data;

    data.reserve(size_t(argc - 3));

    for (int i = 3; i < argc; ++i) {
        data.push_back(parse_byte(argv[i]));
    }

    check_range(address, data.size());
    park(testbench, jtag);
    jtag.write_memory(address, data);

    std::printf("wrote %zu bytes at %08x\n", data.size(), address);
}

bool server_command(int argc, char** argv) {
    return (argc == 2 || argc == 3) && !std::strcmp(argv[1], "server");
}

bool valid_command(int argc, char** argv) {
    return server_command(argc, argv) ||
           (argc == 3 && !std::strcmp(argv[1], "load")) ||
           (argc == 3 && !std::strcmp(argv[1], "test")) ||
           (argc == 3 && !std::strcmp(argv[1], "qspiboot")) ||
           (argc == 3 && !std::strcmp(argv[1], "uartboot")) ||
           (argc == 4 && !std::strcmp(argv[1], "read")) ||
           (argc >= 4 && !std::strcmp(argv[1], "write"));
}

int execute_command(SocTestbench& testbench, Jtag& jtag,
                    int argc, char** argv) {
    if (!std::strcmp(argv[1], "load")) {
        load_command(testbench, jtag, argv[2]);
        return 0;
    }

    if (!std::strcmp(argv[1], "test")) {
        return test_command(testbench, jtag, argv[2]);
    }

    if (!std::strcmp(argv[1], "qspiboot")) {
        return qspiboot_command(testbench, jtag, argv[2]);
    }

    if (!std::strcmp(argv[1], "uartboot")) {
        return uartboot_command(testbench, jtag, argv[2]);
    }

    if (!std::strcmp(argv[1], "read")) {
        read_command(testbench, jtag, argv[2], argv[3]);
        return 0;
    }

    write_command(testbench, jtag, argc, argv);
    return 0;
}

void print_usage(const char* program) {
    std::fprintf(stderr,
                 "usage:\n"
                 "  %s load <program.elf>\n"
                 "  %s test <program.elf>\n"
                 "  %s qspiboot <image.bin>\n"
                 "  %s uartboot <stage.bin>\n"
                 "  %s read <address> <size>\n"
                 "  %s write <address> <byte> [byte ...]\n"
                 "  %s server [port]\n",
                 program, program, program, program, program, program,
                 program);
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    if (!valid_command(argc, argv)) {
        print_usage(argv[0]);
        return 1;
    }

    try {
        SocTestbench testbench;
        Jtag jtag(testbench);

        testbench.reset();

        int result = 0;

        if (server_command(argc, argv)) {
            uint16_t port = argc == 3 ? parse_port(argv[2])
                                      : RemoteBitbang::DEFAULT_PORT;
            RemoteBitbang(testbench).serve(port);
        } else {
            jtag.initialize();
            result = execute_command(testbench, jtag, argc, argv);
        }

        return result;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "JTAG simulation failed: %s\n", error.what());
        return 1;
    }
}

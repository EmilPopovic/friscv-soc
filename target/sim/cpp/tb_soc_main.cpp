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
#include <string>
#include <vector>

#include "elf_loader.hpp"
#include "jtag.hpp"
#include "remote_bitbang.hpp"
#include "soc_memory.hpp"
#include "soc_testbench.hpp"

namespace {

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

// STAGE_BYTES and UART_DIV in zsbl.S
constexpr size_t   ZSBL_STAGE_BYTES = 0x1000;
constexpr uint32_t ZSBL_UART_DIV = 27;
// The stage checks the tail, so a short transfer cannot pass
constexpr size_t   STAGE_PATTERN_START = 1024;


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


// A bad VERNII_* value is an error rather than a silent zero
uint64_t env_u64(const char* name, uint64_t fallback) {
    const char* text = std::getenv(name);

    if (text == nullptr) {
        return fallback;
    }

    char* end = nullptr;
    unsigned long long value = std::strtoull(text, &end, 0);

    if (!text[0] || *end) {
        throw std::runtime_error(std::string(name) + " is not a number");
    }

    return value;
}

uint32_t env_u32(const char* name, uint32_t fallback) {
    uint64_t value = env_u64(name, fallback);

    if (value > std::numeric_limits<uint32_t>::max()) {
        throw std::runtime_error(std::string(name) + " does not fit in 32 bits");
    }

    return uint32_t(value);
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

// Reset, then wait for the boot ROM to reach its idle loop
void park(SocTestbench& testbench, Jtag& jtag) {
    jtag.reset_soc();

    for (unsigned i = 0; i < 1000; ++i) {
        if (read_word(jtag, SCRATCH_ADDRESS) == PARKED) {
            return;
        }

        testbench.run_cycles(8);
    }

    throw std::runtime_error("boot ROM did not park");
}

void start_image(Jtag& jtag, uint32_t entry) {
    jtag.write_memory(SCRATCH_ADDRESS, word_bytes(entry));
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


std::vector<uint8_t> read_file(const char* path) {
    std::FILE* file = std::fopen(path, "rb");

    if (file == nullptr) {
        throw std::runtime_error(std::string("cannot open ") + path);
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

void preload_flash(SocTestbench& testbench, const char* path) {
    std::vector<uint8_t> data = read_file(path);

    testbench.flash().preload(0, data);
    std::fprintf(stderr, "flash image %s: %zu bytes\n", path, data.size());
}

void preload_sd(SocTestbench& testbench, const char* path) {
    std::vector<uint8_t> data = read_file(path);

    testbench.sd().preload(0, data);
    std::fprintf(stderr, "sd image %s: %zu bytes\n", path, data.size());
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
    if (std::getenv("VERNII_LLCSEL") == nullptr) {
        return;
    }

    jtag.write_memory(SCB_LLCSEL, word_bytes(env_u32("VERNII_LLCSEL", 0)));
}

// VERNII_UART_DIV sets the 16550 divisor for software that expects a boot stub
// to have done it, and gives the monitor its bit period
void apply_uart_config(SocTestbench& testbench, Jtag& jtag) {
    if (std::getenv("VERNII_UART_DIV") == nullptr) {
        return;
    }

    uint32_t divisor = env_u32("VERNII_UART_DIV", 0);

    jtag.write_memory(UART0_BASE + 0x0c, word_bytes(0x80));      // DLAB
    jtag.write_memory(UART0_BASE + 0x00, word_bytes(divisor & 0xFF));
    jtag.write_memory(UART0_BASE + 0x04, word_bytes(divisor >> 8));
    jtag.write_memory(UART0_BASE + 0x0c, word_bytes(0x03));      // 8N1

    testbench.uart().set_divisor(divisor);
}

// Media for programs that drive the flash or the card themselves
void apply_media(SocTestbench& testbench) {
    if (const char* path = std::getenv("VERNII_FLASH")) {
        preload_flash(testbench, path);
    }

    if (const char* path = std::getenv("VERNII_SD_IMAGE")) {
        preload_sd(testbench, path);
    }
}

ElfImage prepare_image(SocTestbench& testbench, Jtag& jtag, const char* path) {
    ElfImage image = read_elf(path);

    validate(image);
    park(testbench, jtag);
    apply_hyperbus_config(jtag);
    apply_cache_config(jtag);
    apply_uart_config(testbench, jtag);
    apply_media(testbench);

    return image;
}


// Come out of reset on a strap
void boot(SocTestbench& testbench, Jtag& jtag, unsigned boot_sel) {
    dut::set_boot_sel(testbench.top(), boot_sel);
    testbench.reset();
    jtag.initialize();  // the reset above took the debug module with it
}

// Run to ebreak or out of budget, then read the verdict
int run_to_end(SocTestbench& testbench, Jtag& jtag) {
    Dut& top = testbench.top();
    uint64_t limit = env_u64("VERNII_TEST_CYCLES", TEST_CYCLES);

    for (uint64_t cycle = 0; cycle < limit && !top.end_o; ++cycle) {
        testbench.run_cycles(1);
    }

    // Do not append the verdict to a line the program left open
    if (!testbench.uart().at_line_start()) {
        std::fputc('\n', stderr);
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

int cmd_load(SocTestbench& testbench, Jtag& jtag, int, char** argv) {
    ElfImage image = prepare_image(testbench, jtag, argv[2]);

    for (const ElfSegment& segment : image.segments) {
        jtag.write_memory(segment.address, segment.data);
    }

    start_image(jtag, image.entry);
    testbench.run_cycles(RUN_CYCLES);
    return 0;
}

int cmd_test(SocTestbench& testbench, Jtag& jtag, int, char** argv) {
    ElfImage image = prepare_image(testbench, jtag, argv[2]);

    // An image outside the SRAM belongs to the external memory
    if (is_external(image.entry)) {
        for (const ElfSegment& segment : image.segments) {
            testbench.ext_mem().preload(segment.address - MEM_BASE, segment.data);
        }
    } else {
        preload_sram(testbench.top(), image, SRAM_BASE);
    }

    start_image(jtag, image.entry);
    return run_to_end(testbench, jtag);
}

// Boot select 1: the ROM takes its first stage out of the flash
int cmd_qspiboot(SocTestbench& testbench, Jtag& jtag, int, char** argv) {
    preload_flash(testbench, argv[2]);

    if (const char* path = std::getenv("VERNII_SD_IMAGE")) {
        preload_sd(testbench, path);
    }

    // The stage sets the divisor itself, this is only for the monitor
    testbench.uart().set_divisor(env_u32("VERNII_UART_DIV", 0));

    boot(testbench, jtag, 1);
    return run_to_end(testbench, jtag);
}

// Boot select 2: the ROM takes its first stage off the UART instead
int cmd_uartboot(SocTestbench& testbench, Jtag& jtag, int, char** argv) {
    std::vector<uint8_t> stage = read_file(argv[2]);

    if (stage.size() > ZSBL_STAGE_BYTES) {
        std::fprintf(stderr, "stage %s is %zu bytes, the rom takes %zu\n",
                     argv[2], stage.size(), ZSBL_STAGE_BYTES);
        return 1;
    }

    stage.resize(ZSBL_STAGE_BYTES, 0);

    for (size_t i = STAGE_PATTERN_START; i < ZSBL_STAGE_BYTES; ++i) {
        stage[i] = uint8_t(i * 7 + 0x5a);
    }

    uint32_t divisor = env_u32("VERNII_UART_DIV", ZSBL_UART_DIV);

    testbench.uart().set_divisor(divisor);
    testbench.uart_rx().set_divisor(divisor);

    // VERNII_UART_BIT_CYCLES models a host clock that differs from the chip's
    testbench.uart_rx().set_bit_cycles(
        env_u32("VERNII_UART_BIT_CYCLES", 16 * divisor));

    boot(testbench, jtag, env_u32("VERNII_BOOT_SEL", 2));

    testbench.uart_rx().send(stage);
    std::fprintf(stderr, "uart stage %s: %zu bytes at divisor %u\n",
                 argv[2], stage.size(), divisor);

    return run_to_end(testbench, jtag);
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

int cmd_read(SocTestbench& testbench, Jtag& jtag, int, char** argv) {
    uint32_t address = parse_u32(argv[2]);
    uint32_t size = parse_u32(argv[3]);

    check_range(address, size);
    park(testbench, jtag);
    print_memory(address, jtag.read_memory(address, size));
    return 0;
}

int cmd_write(SocTestbench& testbench, Jtag& jtag, int argc, char** argv) {
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
    return 0;
}

int cmd_server(SocTestbench& testbench, Jtag&, int argc, char** argv) {
    uint16_t port = argc == 3 ? parse_port(argv[2]) : RemoteBitbang::DEFAULT_PORT;

    RemoteBitbang(testbench).serve(port);
    return 0;
}


struct Command {
    const char* name;
    int         argc;   // exact, or negative for a minimum of -argc
    bool        jtag;   // whether the debug module comes up first
    int       (*run)(SocTestbench&, Jtag&, int, char**);
    const char* usage;
};

constexpr Command COMMANDS[] = {
    { "load",     3,  true,  cmd_load,     "load <program.elf>"                },
    { "test",     3,  true,  cmd_test,     "test <program.elf>"                },
    { "qspiboot", 3,  true,  cmd_qspiboot, "qspiboot <image.bin>"              },
    { "uartboot", 3,  true,  cmd_uartboot, "uartboot <stage.bin>"              },
    { "read",     4,  true,  cmd_read,     "read <address> <size>"             },
    { "write",   -4,  true,  cmd_write,    "write <address> <byte> [byte ...]" },
    { "server",  -2,  false, cmd_server,   "server [port]"                     },
};

const Command* find_command(int argc, char** argv) {
    if (argc < 2) {
        return nullptr;
    }

    for (const Command& command : COMMANDS) {
        if (std::strcmp(argv[1], command.name) != 0) {
            continue;
        }

        bool ok = command.argc < 0 ? argc >= -command.argc
                                   : argc == command.argc;
        return ok ? &command : nullptr;
    }

    return nullptr;
}

void print_usage(const char* program) {
    std::fprintf(stderr, "usage:\n");

    for (const Command& command : COMMANDS) {
        std::fprintf(stderr, "  %s %s\n", program, command.usage);
    }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const Command* command = find_command(argc, argv);

    if (command == nullptr) {
        print_usage(argv[0]);
        return 1;
    }

    try {
        SocTestbench testbench;
        Jtag jtag(testbench);

        testbench.sd().set_miso_delay(env_u32("VERNII_SD_MISO_DELAY", 0));

        testbench.reset();

        if (command->jtag) {
            jtag.initialize();
        }

        return command->run(testbench, jtag, argc, argv);
    } catch (const std::exception& error) {
        std::fprintf(stderr, "simulation failed: %s\n", error.what());
        return 1;
    }
}

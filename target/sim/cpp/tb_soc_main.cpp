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

#ifndef FRISCV_SOC_SRAM_BASE
#define FRISCV_SOC_SRAM_BASE 0
#endif

#ifndef FRISCV_SOC_SRAM_SIZE_BYTES
#define FRISCV_SOC_SRAM_SIZE_BYTES 0x2000
#endif

constexpr uint32_t MEM_BASE = 0x80000000;
constexpr uint32_t UART0_BASE = 0x10000000;
constexpr uint32_t SCB_HBCTL = 0x40000008;
constexpr uint32_t SCB_LLCSEL = 0x4000000C;
constexpr uint32_t HYPER_CFG_BASE = 0x50010000;
constexpr uint32_t SCRATCH_ADDRESS = 0x40000000;
constexpr uint32_t PARKED = 1;
constexpr uint32_t PASS_VALUE = 0xaabbccdd;
constexpr uint32_t SRAM_BASE = FRISCV_SOC_SRAM_BASE;
constexpr uint32_t SRAM_SIZE = FRISCV_SOC_SRAM_SIZE_BYTES;
constexpr uint16_t RISCV_MACHINE = 243;
constexpr uint64_t RUN_CYCLES = 2000;
constexpr uint64_t TEST_CYCLES = 10000000;

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

// The arch-test build relocates the SRAM over MEM_BASE, so "external" means
// outside the SRAM rather than simply at or above MEM_BASE
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

// FRISCV_HB_CFG="reg:value[,...]" sets the HyperBus controller config before the
// program runs, so a sweep does not have to rebuild the program
void apply_hyperbus_config(Jtag& jtag) {
    const char* spec = std::getenv("FRISCV_HB_CFG");

    if (spec == nullptr) {
        return;
    }

    while (*spec != '\0') {
        char* end = nullptr;
        unsigned long index = std::strtoul(spec, &end, 0);

        if (end == spec || *end != ':') {
            throw std::runtime_error("FRISCV_HB_CFG wants reg:value pairs");
        }

        spec = end + 1;
        unsigned long value = std::strtoul(spec, &end, 0);

        if (end == spec) {
            throw std::runtime_error("FRISCV_HB_CFG wants reg:value pairs");
        }

        jtag.write_memory(HYPER_CFG_BASE + uint32_t(index) * 4,
                          word_bytes(uint32_t(value)));
        std::fprintf(stderr, "hyperbus cfg[%lu] = %lu\n", index, value);

        spec = (*end == ',') ? end + 1 : end;
    }
}

// FRISCV_LLCSEL enables the HyperBus and marks ways as cache before the program
// starts, so an image linked into the cached region can run from there
void apply_cache_config(Jtag& jtag) {
    const char* mask = std::getenv("FRISCV_LLCSEL");

    if (mask == nullptr) {
        return;
    }

    jtag.write_memory(SCB_HBCTL, word_bytes(1));
    jtag.write_memory(SCB_LLCSEL, word_bytes(uint32_t(std::strtoul(mask, nullptr, 0))));
}

// FRISCV_UART_DIV programs the 16550 divisor before the image runs, for
// software that expects a boot stub to have set the baud rate already, and
// gives the monitor the bit period that follows from it
void apply_uart_config(SocTestbench& testbench, Jtag& jtag) {
    const char* div = std::getenv("FRISCV_UART_DIV");

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

ElfImage prepare_image(SocTestbench& testbench, Jtag& jtag,
                       const char* path) {
    ElfImage image = read_elf(path);
    validate(image);
    park(testbench, jtag);
    apply_hyperbus_config(jtag);
    apply_cache_config(jtag);
    apply_uart_config(testbench, jtag);

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

int test_command(SocTestbench& testbench, Jtag& jtag, const char* path) {
    Vfriscv_soc& top = testbench.top();
    ElfImage image = prepare_image(testbench, jtag, path);

    // An image outside the SRAM belongs to the external memory
    if (is_external(image.entry)) {
        for (const ElfSegment& segment : image.segments) {
            testbench.hyperram().preload(segment.address - MEM_BASE, segment.data);
        }
    } else {
        preload_sram(top, image, SRAM_BASE);
    }
    start_image(jtag, image.entry);

    uint64_t limit = TEST_CYCLES;

    if (const char* env = std::getenv("FRISCV_TEST_CYCLES")) {
        limit = std::strtoull(env, nullptr, 0);
    }

    for (uint64_t cycle = 0; cycle < limit && !top.o_end; ++cycle) {
        testbench.run_cycles(1);
    }

    uint32_t result = read_word(jtag, SCRATCH_ADDRESS);

    // From reset, so the count does not shift with debug-module traffic
    unsigned long long cycles = testbench.cycles();

    if (top.o_end && result == PASS_VALUE) {
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
                 "  %s read <address> <size>\n"
                 "  %s write <address> <byte> [byte ...]\n"
                 "  %s server [port]\n",
                 program, program, program, program, program);
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

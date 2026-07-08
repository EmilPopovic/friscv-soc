#include "Vfriscv_cpu_verilator.h"
#include "verilated.h"

#include <cstdio>
#include <cstring>
#include <stdexcept>

#include "paged_mem.hpp"
#include "mem_model.hpp"
#include "elf_loader.hpp"
#include "bus.hpp"
#include "uart16550_model.hpp"

static uint64_t cycle_count = 0;

static constexpr uint32_t MEM_BASE_ADDR = 0x80000000u;
static constexpr uint32_t MEM_SIZE      = 0x01000000u;  // 16 MB

static constexpr uint32_t UART_BASE_ADDR = 0x10000000u;
static constexpr uint32_t GPIO_BASE_ADDR = 0x40000000u;
static constexpr uint32_t HALT_BASE_ADDR = 0x50000000u;

static constexpr uint32_t PASS_VALUE = 0xAABBCCDDu;

static constexpr int MEM_WAIT_CYCLES = 0;

static constexpr uint64_t MAX_CYCLES = 10000000;  // 10M cycles

uint64_t mtime() {
    return cycle_count / 10;
}

void posedge(Vfriscv_cpu_verilator* top) {
    cycle_count++;
    top->clk = 1;
    top->eval();
}

void negedge(Vfriscv_cpu_verilator* top) {
    top->clk = 0;
    top->eval();
}

void cycle(Vfriscv_cpu_verilator* top, BusRouter& bus) {
    // Posedge for the core
    posedge(top);

    // Evaluate memory model
    bus.cycle(top->size, top->addr, top->wdata,
              top->w_en, top->r_en, top->burst_en);

    top->rdata      = bus.rdata;
    top->stall      = bus.wait;
    top->beat_valid = bus.beat_valid;
    top->err        = bus.err;

    negedge(top);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    const char* elf_path = nullptr;
    for (int i = 1; i < argc - 1; i++) {
        if (std::strcmp(argv[i], "--elf") == 0) elf_path = argv[i+1];
    }
    if (!elf_path) {
        std::fprintf(stderr, "usage: %s --elf <path>\n", argv[0]);
        return 1;
    }

    PagedMem mem_pool(MEM_BASE_ADDR, MEM_SIZE);
    try {
        load_elf(elf_path, &mem_pool);
    } catch (const std::exception& e) {
        std::fprintf(stderr, "failed to load '%s': %s\n", elf_path, e.what());
        return 1;
    }

    // Instantiate top module
    Vfriscv_cpu_verilator* top = new Vfriscv_cpu_verilator;

    // Build the bus and address map
    MemModel       dram(&mem_pool, MEM_WAIT_CYCLES);
    Uart16550Model uart;
    SinkDevice     gpio, halt_sink;
    BusRouter      bus;

    bus.map(MEM_BASE_ADDR,  MEM_SIZE, &dram);
    bus.map(UART_BASE_ADDR, 0x20,     &uart);
    bus.map(GPIO_BASE_ADDR, 4,        &gpio);
    bus.map(HALT_BASE_ADDR, 4,        &halt_sink);

    // Initialize into reset
    top->rstn = 0;
    top->clk = 0;
    top->eval();

    top->msip = 0;
    top->mtip = 0;
    top->meip = 0;

    // Reset for 20 cycles
    for (int i = 0; i < 20 && !Verilated::gotFinish(); i++) cycle(top, bus);

    top->rstn = 1;  // Release reset
    // Run until halt or timeout
    while (!top->halt && cycle_count < MAX_CYCLES && !Verilated::gotFinish()) {
        cycle(top, bus);
        top->mtime = mtime();
    }

    int exit_code;
    if (gpio.get_last_write() == PASS_VALUE) {
        std::fprintf(stderr, "PASS\n");
        exit_code = 0;
    } else {
        std::fprintf(stderr, "FAIL (gpio=0x%08X)\n", gpio.get_last_write());
        exit_code = 1;
    }

    top->final();
    delete top;
    return exit_code;
}

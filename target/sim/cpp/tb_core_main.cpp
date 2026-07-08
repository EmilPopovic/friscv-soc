#include "Vfriscv_cpu_verilator.h"
#include "verilated.h"

#include <cstdio>
#include <cstring>
#include <stdexcept>

#include "paged_mem.hpp"
#include "mem_model.hpp"
#include "elf_loader.hpp"

#define MEM_BASE_ADDR (0x80000000u)
#define MEM_SIZE      (0x01000000u)  // 16 MB
#define MEM_WAIT_CYCLES (0)

static uint64_t cycle_count = 0;

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

void cycle(Vfriscv_cpu_verilator* top, MemModel& mem) {
    // Posedge for the core
    posedge(top);

    // Evaluate memory model
    mem.cycle(top->size, top->addr, top->wdata,
              top->w_en, top->r_en, top->burst_en);
    top->rdata      = mem.rdata;
    top->stall      = mem.wait;
    top->beat_valid = mem.beat_valid;
    top->err        = mem.err;

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

    Vfriscv_cpu_verilator* top = new Vfriscv_cpu_verilator;

    MemModel mem(&mem_pool, MEM_WAIT_CYCLES);

    top->rstn = 0;
    top->clk = 0;
    top->eval();

    top->msip = 0;
    top->mtip = 0;
    top->meip = 0;

    // Reset for 20 cycles
    for (int i = 0; i < 20 && !Verilated::gotFinish(); i++) cycle(top, mem);

    top->rstn = 1;  // Release reset
    while (!top->halt) {
        cycle(top, mem);
        top->mtime = mtime();
    }

    top->final();
    delete top;
    return 0;
}

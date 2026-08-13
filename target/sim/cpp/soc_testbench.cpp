// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
// Emil Popović <mail@emilpopovic.me>

#include "soc_testbench.hpp"

namespace {

constexpr unsigned RESET_CYCLES = 20;

}  // namespace

SocTestbench::SocTestbench() : ext_mem_(top_), flash_(top_) {
    top_.i_clk = 0;
    top_.i_rstn = 0;
    top_.i_uart_rx = 1;
    top_.i_jtag_tck = 0;
    top_.i_jtag_tms = 1;
    top_.i_jtag_tdi = 0;
    top_.i_jtag_trstn = 1;
    dut::clear_inputs(top_);

    eval();
}

SocTestbench::~SocTestbench() {
    top_.final();
}

void SocTestbench::eval() {
    top_.eval();
    ext_mem_.update();
    flash_.update();
    top_.eval();
}

void SocTestbench::reset() {
    top_.i_rstn = 0;
    run_cycles(RESET_CYCLES);

    top_.i_rstn = 1;
    run_cycles(RESET_CYCLES);
}

void SocTestbench::run_cycles(uint64_t count) {
    cycles_ += count;

    for (uint64_t i = 0; i < count; ++i) {
        uart_.sample(top_.o_uart_tx);

        // The loop leaves the clock low, so a leading low phase would only
        // re-evaluate an unchanged model
        top_.i_clk = 1;
        eval();

        top_.i_clk = 0;
        eval();
    }
}

// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
// Emil Popović <mail@emilpopovic.me>

#include "soc_testbench.hpp"

namespace {

constexpr unsigned RESET_CYCLES = 20;

// Blocks the card comes up holding
constexpr unsigned SD_PATTERN_BLOCKS = 4;

}  // namespace

SocTestbench::SocTestbench() : ext_mem_(top_), flash_(top_), sd_(top_) {
    sd_.fill_test_pattern(SD_PATTERN_BLOCKS);

    top_.clk_i = 0;
    top_.rst_ni = 0;
    top_.uart0_rx_i = 1;
    top_.jtag_tck_i = 0;
    top_.jtag_tms_i = 1;
    top_.jtag_tdi_i = 0;
    top_.jtag_trst_ni = 1;
    dut::clear_inputs(top_);

    eval();
}

SocTestbench::~SocTestbench() {
    top_.final();
}

void SocTestbench::drive_miso() {
    // One line, two devices. Whichever holds chip select owns it, and it idles
    // high the way a pulled up bus does.
    bool value = true;

    if (flash_.driving()) {
        value = flash_.miso();
    } else if (sd_.driving()) {
        value = sd_.miso();
    }

    dut::qspi_miso(top_, value);
}

void SocTestbench::eval() {
    top_.eval();
    ext_mem_.update();
    flash_.update();
    sd_.update();
    drive_miso();
    top_.eval();
}

void SocTestbench::reset() {
    top_.rst_ni = 0;
    run_cycles(RESET_CYCLES);

    top_.rst_ni = 1;
    run_cycles(RESET_CYCLES);
}

void SocTestbench::run_cycles(uint64_t count) {
    cycles_ += count;

    for (uint64_t i = 0; i < count; ++i) {
        uart_.sample(top_.uart0_tx_o);
        top_.uart0_rx_i = uart_rx_.drive();

        // The loop ends with the clock low, a leading low phase would be a no-op
        top_.clk_i = 1;
        eval();

        top_.clk_i = 0;
        eval();
    }
}

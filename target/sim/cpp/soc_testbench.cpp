#include "soc_testbench.hpp"

namespace {

constexpr unsigned RESET_CYCLES = 20;

}  // namespace

SocTestbench::SocTestbench() : hyperram_(top_) {
    top_.i_clk = 0;
    top_.i_rstn = 0;
    top_.i_uart_rx = 1;
    top_.i_jtag_tck = 0;
    top_.i_jtag_tms = 1;
    top_.i_jtag_tdi = 0;
    top_.i_pa0 = 0;
    top_.i_pa1 = 0;
    top_.i_pa2 = 0;
    top_.pad_in_i = 0;

    eval();
}

SocTestbench::~SocTestbench() {
    top_.final();
}

void SocTestbench::eval() {
    top_.eval();
    hyperram_.update();
    top_.eval();
}

void SocTestbench::reset() {
    top_.i_rstn = 0;
    run_cycles(RESET_CYCLES);

    top_.i_rstn = 1;
    run_cycles(RESET_CYCLES);
}

void SocTestbench::run_cycles(uint64_t count) {
    for (uint64_t i = 0; i < count; ++i) {
        top_.i_clk = 0;
        eval();

        top_.i_clk = 1;
        eval();

        top_.i_clk = 0;
        eval();
    }
}

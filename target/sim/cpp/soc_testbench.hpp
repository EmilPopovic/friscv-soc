#pragma once

#include <cstdint>

#include "dut.hpp"
#include "qspi_flash.hpp"
#include "uart_tx_monitor.hpp"

#ifdef FRISCV_TB_CHIP
#include "hyperram.hpp"
using ExtMem = Hyperram;
#else
#include "axi_mem.hpp"
using ExtMem = AxiMem;
#endif

class SocTestbench {
  public:
    SocTestbench();
    ~SocTestbench();

    Dut& top() { return top_; }
    ExtMem& ext_mem() { return ext_mem_; }
    QspiFlash& flash() { return flash_; }
    UartTxMonitor& uart() { return uart_; }

    void reset();
    void run_cycles(uint64_t count);
    uint64_t cycles() const { return cycles_; }

  private:
    void eval();

    Dut top_;
    ExtMem ext_mem_;
    QspiFlash flash_;
    UartTxMonitor uart_;
    uint64_t cycles_ = 0;
};

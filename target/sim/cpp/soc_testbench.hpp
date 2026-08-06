#pragma once

#include <cstdint>

#include "Vfriscv_soc.h"
#include "hyperram.hpp"
#include "qspi_flash.hpp"
#include "uart_tx_monitor.hpp"

class SocTestbench {
  public:
    SocTestbench();
    ~SocTestbench();

    Vfriscv_soc& top() { return top_; }
    Hyperram& hyperram() { return hyperram_; }
    QspiFlash& flash() { return flash_; }
    UartTxMonitor& uart() { return uart_; }

    void reset();
    void run_cycles(uint64_t count);
    uint64_t cycles() const { return cycles_; }

  private:
    void eval();

    Vfriscv_soc top_;
    Hyperram hyperram_;
    QspiFlash flash_;
    UartTxMonitor uart_;
    uint64_t cycles_ = 0;
};

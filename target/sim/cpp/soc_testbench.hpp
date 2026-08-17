// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
// Emil Popović <mail@emilpopovic.me>

#pragma once

#include <cstdint>

#include "axi_mem.hpp"
#include "dut.hpp"
#include "qspi_flash.hpp"
#include "uart_rx_driver.hpp"
#include "uart_tx_monitor.hpp"

class SocTestbench {
  public:
    SocTestbench();
    ~SocTestbench();

    Dut& top() { return top_; }
    AxiMem& ext_mem() { return ext_mem_; }
    QspiFlash& flash() { return flash_; }
    UartTxMonitor& uart() { return uart_; }
    UartRxDriver& uart_rx() { return uart_rx_; }

    void reset();
    void run_cycles(uint64_t count);
    uint64_t cycles() const { return cycles_; }

  private:
    void eval();

    Dut top_;
    AxiMem ext_mem_;
    QspiFlash flash_;
    UartTxMonitor uart_;
    UartRxDriver uart_rx_;
    uint64_t cycles_ = 0;
};

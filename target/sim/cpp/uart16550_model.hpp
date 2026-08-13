// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>

#pragma once

#include "bus.hpp"

class Uart16550Model : public BusDevice {
  public:
    void cycle(uint8_t size, uint32_t offset, uint32_t wdata,
               bool w_en, bool r_en, bool burst_en) override;
  private:
    bool dlab() const { return lcr & 0x80; }

    uint8_t ier = 0;  // Interrupt Enable Register
    uint8_t lcr = 0;  // Line Control Register
    uint8_t mcr = 0;  // Modem Control Register
    uint8_t scr = 0;  // Scratch Register
    uint8_t dll = 0;  // Divisor Latch LSB
    uint8_t dlm = 0;  // Divisor Latch MSB
};

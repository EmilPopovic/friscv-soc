// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
// Emil Popović <mail@emilpopovic.me>

#pragma once

#include <cstdint>

#include "bus.hpp"

class ClintModel : public BusDevice {
  public:
    ClintModel();

    void reset();
    void cycle(uint8_t size, uint32_t offset, uint32_t wdata,
               bool w_en, bool r_en, bool burst_en) override;

    uint64_t get_mtime() const { return mtime; }
    bool get_msip() const { return msip; }
    bool get_mtip() const { return mtime >= mtimecmp; }

  private:
    static constexpr uint32_t MTIME_DIV = 5;  // 50 MHz core / 10 MHz mtime

    uint64_t mtime;
    uint64_t mtimecmp;
    bool     msip;
    bool     suppress_tick;
    uint32_t prescaler;

    void tick();
    uint32_t read_reg(uint32_t offset) const;
    void write_reg(uint32_t offset, uint32_t data);
};

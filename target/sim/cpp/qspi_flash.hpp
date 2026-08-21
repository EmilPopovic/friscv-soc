// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>
// Matej Jurasić <matej.jurasic@cappig.dev>

#pragma once

#include <cstdint>
#include <vector>

#include "paged_mem.hpp"

#include "dut.hpp"

// SPI NOR flash, single-bit reads only
class QspiFlash {
  public:
    explicit QspiFlash(Dut& top);

    void update();
    void preload(uint32_t address, const std::vector<uint8_t>& data);

    bool driving() const { return selected_; }
    bool miso() const { return miso_; }

  private:
    static constexpr unsigned CS_INDEX = 0;

    enum class Phase {
        Command,
        Address,
        Read,
        Id,
    };

    static constexpr uint32_t MEMORY_SIZE = 0x1000000;  // 24-bit addresses

    void begin_transaction();
    void sample_bit(bool mosi);
    void drive_bit();
    void finish_byte();

    Dut& top_;
    PagedMem memory_;
    Phase phase_ = Phase::Command;
    uint8_t shift_in_ = 0;
    uint8_t shift_out_ = 0;
    unsigned bit_ = 0;
    unsigned address_bytes_ = 0;
    uint32_t address_ = 0;
    bool clock_ = false;
    bool selected_ = false;
    bool miso_ = false;
};

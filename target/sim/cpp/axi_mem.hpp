// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>

#pragma once

#include <cstdint>
#include <vector>

#include "dut.hpp"
#include "paged_mem.hpp"

class AxiMem {
  public:
    explicit AxiMem(Dut& top);

    void update();
    void preload(uint32_t address, const std::vector<uint8_t>& data);

  private:
    static constexpr uint32_t MEMORY_SIZE = 0x10000000;

    struct Sample {
        bool     aw_valid = false;
        uint32_t aw_addr = 0;
        unsigned aw_len = 0;
        unsigned aw_size = 0;
        bool     aw_id = false;
        bool     w_valid = false;
        uint32_t w_data = 0;
        unsigned w_strb = 0;
        bool     w_last = false;
        bool     b_ready = false;
        bool     ar_valid = false;
        uint32_t ar_addr = 0;
        unsigned ar_len = 0;
        unsigned ar_size = 0;
        bool     ar_id = false;
        bool     r_ready = false;
    };

    void capture();
    void drive();
    void process();

    uint32_t read_word(uint32_t address);
    void write_word(uint32_t address, uint32_t data, unsigned strb);

    Dut& top_;
    PagedMem memory_;
    Sample sample_;

    bool clock_ = false;

    bool aw_ready_ = true;
    bool w_ready_ = false;
    bool b_valid_ = false;
    bool b_id_ = false;
    bool ar_ready_ = true;
    bool r_valid_ = false;
    bool r_last_ = false;
    bool r_id_ = false;
    uint32_t r_data_ = 0;

    uint32_t write_address_ = 0;
    unsigned write_size_ = 0;
    uint32_t read_address_ = 0;
    unsigned read_size_ = 0;
    unsigned read_beats_ = 0;
};

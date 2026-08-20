// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

#pragma once

#include <cstdint>
#include <deque>
#include <vector>

#include "dut.hpp"
#include "paged_mem.hpp"

// An SDHC card in SPI mode on QSPI0 CS1, mode 0. Single-block reads only.
// Init is enforced: 74 clocks with CS high, CRC on CMD0 and CMD8, busy bytes.
class SdCard {
  public:
    explicit SdCard(Dut& top);

    void update();
    void preload(uint32_t block, const std::vector<uint8_t>& data);
    void fill_test_pattern(unsigned blocks);

    static uint8_t pattern_byte(uint32_t block, unsigned offset);

    // Launch edge to pin, in core clocks
    void set_miso_delay(unsigned cycles);

    bool driving() const { return selected_; }
    bool miso() const;

  private:
    static constexpr unsigned CS_INDEX = 1;
    static constexpr uint32_t BLOCK_BYTES = 512;
    static constexpr uint32_t MEMORY_SIZE = 0x800000;
    static constexpr unsigned MAX_DELAY = 16;

    // Only counted while CS is high
    static constexpr unsigned REQUIRED_INIT_CLOCKS = 74;
    // Busy bytes before a response, N_CR in the spec
    static constexpr unsigned RESPONSE_DELAY_BYTES = 2;
    // Busy bytes between the CMD17 response and the data token
    static constexpr unsigned READ_ACCESS_BYTES = 3;

    void begin_transaction();
    void sample_bit(bool mosi);
    void present_bit();
    void finish_byte();
    void process_command();
    void respond(const std::vector<uint8_t>& bytes);
    uint8_t next_out_byte();
    void advance_delay();

    Dut& top_;
    PagedMem memory_;

    bool selected_ = false;
    bool clock_ = false;
    bool core_clock_ = false;

    unsigned idle_clocks_ = 0;

    uint8_t  shift_in_ = 0;
    unsigned bit_in_ = 0;
    uint8_t  cmd_[6] = {};
    unsigned cmd_len_ = 0;
    bool     in_cmd_ = false;

    uint8_t  out_byte_ = 0xff;
    unsigned out_bit_ = 0;
    std::deque<uint8_t> out_queue_;

    bool     initialised_ = false;
    bool     app_cmd_ = false;
    bool     ready_ = false;
    unsigned acmd41_count_ = 0;

    bool miso_raw_ = true;
    unsigned delay_ = 0;
    std::deque<bool> pipe_;
};

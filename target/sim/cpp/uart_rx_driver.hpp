// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

#pragma once

#include <cstdint>
#include <deque>
#include <vector>

// Drives uart0_rx_i as 8N1
class UartRxDriver {
  public:
    void set_divisor(unsigned divisor);

    // Bit period straight from the host
    void set_bit_cycles(unsigned cycles) { bit_cycles_ = cycles; }

    void send(const std::vector<uint8_t>& bytes);

    bool idle() const { return queue_.empty() && state_ == State::IDLE; }

    bool drive();  // once per clock cycle

  private:
    enum class State { IDLE, START, DATA, STOP };

    unsigned bit_cycles_ = 0;  // zero until the divisor is known
    State    state_      = State::IDLE;
    unsigned counter_    = 0;
    unsigned bit_index_  = 0;
    uint8_t  shifter_    = 0;
    bool     level_      = true;
    std::deque<uint8_t> queue_;
};

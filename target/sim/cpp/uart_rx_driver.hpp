// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

#pragma once

#include <cstdint>
#include <deque>
#include <vector>

// Drives uart0_rx_i, the other half of UartTxMonitor. 8N1 only, and holds the
// line idle until it is given the divisor.
class UartRxDriver {
  public:
    void set_divisor(unsigned divisor);

    // Set the bit period directly, to model a host clock that does not match
    // the chip's. The ROM cannot adapt, so this is where its margin shows.
    void set_bit_cycles(unsigned cycles) { bit_cycles_ = cycles; }

    void send(const std::vector<uint8_t>& bytes);

    bool idle() const { return queue_.empty() && state_ == State::IDLE; }

    bool drive();  // once per clock cycle, returns the line level

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

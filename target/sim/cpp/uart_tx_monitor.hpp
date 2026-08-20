// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

#pragma once

// Decodes o_uart_tx to see what software prints. 8N1, quiet until given a divisor.
class UartTxMonitor {
  public:
    void set_divisor(unsigned divisor);
    void sample(bool tx);  // once per clock cycle

    bool at_line_start() const { return at_line_start_; }

  private:
    enum class State { IDLE, START, DATA, STOP };

    unsigned bit_cycles_ = 0;  // zero until the divisor is known
    State    state_      = State::IDLE;
    unsigned counter_    = 0;
    unsigned bit_index_  = 0;
    unsigned char shifter_ = 0;
    bool     last_       = true;
    bool     warned_     = false;
    bool     at_line_start_ = true;
};

// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

#pragma once

// Decodes o_uart_tx so simulation can see what software prints. 8N1 only.
// Stays quiet until given the 16550 divisor, which fixes the bit period.
class UartTxMonitor {
  public:
    void set_divisor(unsigned divisor);
    void sample(bool tx);  // once per clock cycle

  private:
    enum class State { IDLE, START, DATA, STOP };

    unsigned bit_cycles_ = 0;  // zero until the divisor is known
    State    state_      = State::IDLE;
    unsigned counter_    = 0;
    unsigned bit_index_  = 0;
    unsigned char shifter_ = 0;
    bool     last_       = true;
    bool     warned_     = false;
};

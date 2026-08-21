// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

#include "uart_tx_monitor.hpp"

#include <cstdio>

// The 16550 oversamples by 16
void UartTxMonitor::set_divisor(unsigned divisor) {
    bit_cycles_ = 16 * divisor;
}

void UartTxMonitor::sample(bool tx) {
    if (bit_cycles_ == 0) {
        return;
    }

    switch (state_) {
        case State::IDLE:
            if (last_ && !tx) {
                state_   = State::START;
                counter_ = 0;
            }
            break;

        case State::START:
            // Re-check mid bit against glitches
            if (++counter_ >= bit_cycles_ / 2) {
                if (tx) {
                    state_ = State::IDLE;
                } else {
                    state_     = State::DATA;
                    counter_   = 0;
                    bit_index_ = 0;
                    shifter_   = 0;
                }
            }
            break;

        case State::DATA:
            if (++counter_ >= bit_cycles_) {
                counter_ = 0;
                shifter_ = (unsigned char)(shifter_ >> 1) | (tx ? 0x80u : 0x00u);
                if (++bit_index_ == 8) {
                    state_ = State::STOP;
                }
            }
            break;

        case State::STOP:
            if (++counter_ >= bit_cycles_) {
                if (tx) {
                    std::fputc(shifter_, stderr);
                    std::fflush(stderr);
                    at_line_start_ = shifter_ == '\n';
                } else if (!warned_) {
                    // No stop bit, the divisor changed
                    warned_ = true;
                    std::fprintf(stderr, "\n[uart] framing error at %u cycles "
                                         "per bit\n", bit_cycles_);
                    at_line_start_ = true;
                }
                state_ = State::IDLE;
            }
            break;
    }

    last_ = tx;
}

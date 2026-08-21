// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

#include "uart_rx_driver.hpp"

// The 16550 oversamples by 16
void UartRxDriver::set_divisor(unsigned divisor) {
    bit_cycles_ = 16 * divisor;
}

void UartRxDriver::send(const std::vector<uint8_t>& bytes) {
    for (uint8_t byte : bytes) {
        queue_.push_back(byte);
    }
}

bool UartRxDriver::drive() {
    if (bit_cycles_ == 0) {
        return true;
    }

    switch (state_) {
        case State::IDLE:
            if (queue_.empty()) {
                level_ = true;
            } else {
                shifter_ = queue_.front();
                queue_.pop_front();
                state_   = State::START;
                counter_ = 0;
                level_   = false;
            }
            break;

        case State::START:
            if (++counter_ >= bit_cycles_) {
                counter_   = 0;
                bit_index_ = 0;
                state_     = State::DATA;
                level_     = (shifter_ & 1) != 0;  // least significant bit first
            }
            break;

        case State::DATA:
            if (++counter_ >= bit_cycles_) {
                counter_ = 0;
                shifter_ = uint8_t(shifter_ >> 1);

                if (++bit_index_ == 8) {
                    state_ = State::STOP;
                    level_ = true;
                } else {
                    level_ = (shifter_ & 1) != 0;
                }
            }
            break;

        case State::STOP:
            if (++counter_ >= bit_cycles_) {
                counter_ = 0;
                state_   = State::IDLE;
                level_   = true;
            }
            break;
    }

    return level_;
}

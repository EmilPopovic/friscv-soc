#include "hyperram.hpp"

#include <stdexcept>

#include "Vfriscv_soc.h"

namespace {

constexpr uint64_t REGISTER_SPACE = uint64_t(1) << 46;
constexpr uint64_t ADDRESS_UPPER_MASK = (uint64_t(1) << 29) - 1;

int selected_chip(uint8_t chip_select) {
    if (chip_select == 0b10) {
        return 0;
    }

    if (chip_select == 0b01) {
        return 1;
    }

    return -1;
}

}  // namespace

Hyperram::Hyperram(Vfriscv_soc& top)
    : top_(top), memory_(0, MEMORY_SIZE) {
    top_.i_hyper_dq = 0;
    top_.i_hyper_rwds = 0;
}

void Hyperram::begin_transaction(uint8_t chip) {
    phase_ = Phase::Command;
    command_ = 0;
    command_bytes_ = 0;
    turnaround_edges_ = 0;
    chip_ = chip;
}

void Hyperram::end_transaction() {
    phase_ = Phase::Idle;
    top_.i_hyper_dq = 0;
    top_.i_hyper_rwds = 0;
}

void Hyperram::sample_command() {
    if (!top_.o_hyper_dq_oe) {
        throw std::runtime_error("HyperRAM command ended early");
    }

    command_ = (command_ << 8) | top_.o_hyper_dq;
    ++command_bytes_;

    if (command_bytes_ == COMMAND_BYTES) {
        finish_command();
    }
}

void Hyperram::finish_command() {
    if (command_ & REGISTER_SPACE) {
        throw std::runtime_error("HyperRAM register access is not supported");
    }

    uint32_t word_address = uint32_t((command_ >> 16) & ADDRESS_UPPER_MASK);
    word_address = (word_address << 3) | uint32_t(command_ & 7);
    address_ = word_address << 1;

    if (!memory_.in_range(address_)) {
        throw std::runtime_error("HyperRAM address is out of range");
    }

    phase_ = Phase::Wait;
}

void Hyperram::drive_read_data(bool rising_edge) {
    uint32_t byte_address = address_ + (rising_edge ? 1 : 0);

    if (!memory_.in_range(byte_address)) {
        throw std::runtime_error("HyperRAM read is out of range");
    }

    top_.i_hyper_dq = memory_.read_byte(byte_address);
    top_.i_hyper_rwds = rising_edge;

    if (!rising_edge) {
        address_ += 2;
    }
}

void Hyperram::sample_write_data(bool rising_edge) {
    uint32_t byte_address = address_ + (rising_edge ? 1 : 0);

    if (!memory_.in_range(byte_address)) {
        throw std::runtime_error("HyperRAM write is out of range");
    }

    if (!top_.o_hyper_rwds) {
        memory_.write_byte(byte_address, top_.o_hyper_dq);
    }

    if (!rising_edge) {
        address_ += 2;
    }
}

void Hyperram::update() {
    bool clock = top_.o_hyper_ck;
    uint8_t chip_select = top_.o_hyper_cs_n & 3;
    int chip = selected_chip(chip_select);

    if (!top_.o_hyper_reset_n || chip < 0) {
        end_transaction();
        clock_ = clock;
        return;
    }

    if (phase_ == Phase::Idle) {
        begin_transaction(uint8_t(chip));
    } else if (chip_ != chip) {
        throw std::runtime_error("HyperRAM chip select changed mid-transaction");
    }

    if (clock == clock_) {
        return;
    }

    clock_ = clock;

    if (phase_ == Phase::Command) {
        sample_command();
        return;
    }

    if (phase_ == Phase::Wait) {
        // Output enables change one clock before the first data beat.
        if (!top_.o_hyper_dq_oe) {
            phase_ = Phase::Read;
            turnaround_edges_ = TURNAROUND_EDGES;
        } else if (top_.o_hyper_rwds_oe) {
            phase_ = Phase::Write;
            turnaround_edges_ = TURNAROUND_EDGES;
        } else {
            return;
        }
    }

    if (turnaround_edges_ != 0) {
        --turnaround_edges_;
        return;
    }

    if (phase_ == Phase::Read) {
        drive_read_data(clock);
    } else if (phase_ == Phase::Write) {
        sample_write_data(clock);
    }
}

#include "hyperram.hpp"

#include <stdexcept>

#include "Vfriscv_soc.h"

namespace {

constexpr uint64_t REGISTER_SPACE = uint64_t(1) << 46;
constexpr uint64_t ADDRESS_UPPER_MASK = (uint64_t(1) << 29) - 1;

constexpr unsigned HB_DQ_LSB   = 13;
constexpr unsigned HB_RWDS_BIT = 21;
constexpr unsigned HB_CK_BIT   = 22;
constexpr unsigned HB_CS_BIT   = 23;
constexpr unsigned HB_RST_BIT  = 24;

uint8_t hb_dq_out(const Vfriscv_soc& top) {
    return uint8_t((top.pad_out_o >> HB_DQ_LSB) & 0xFF);
}

bool hb_dq_oe(const Vfriscv_soc& top) {
    return ((top.pad_oe_o >> HB_DQ_LSB) & 1) != 0;
}

bool hb_rwds_out(const Vfriscv_soc& top) {
    return ((top.pad_out_o >> HB_RWDS_BIT) & 1) != 0;
}

bool hb_rwds_oe(const Vfriscv_soc& top) {
    return ((top.pad_oe_o >> HB_RWDS_BIT) & 1) != 0;
}

bool hb_ck(const Vfriscv_soc& top) {
    return ((top.pad_out_o >> HB_CK_BIT) & 1) != 0;
}

uint8_t hb_cs(const Vfriscv_soc& top) {
    return uint8_t((top.pad_out_o >> HB_CS_BIT) & 1);
}

bool hb_reset_n(const Vfriscv_soc& top) {
    return ((top.pad_out_o >> HB_RST_BIT) & 1) != 0;
}

void set_hb_dq_in(Vfriscv_soc& top, uint8_t value) {
    top.pad_in_i = (top.pad_in_i & ~(uint32_t(0xFF) << HB_DQ_LSB)) |
                   (uint32_t(value) << HB_DQ_LSB);
}

void set_hb_rwds_in(Vfriscv_soc& top, bool value) {
    top.pad_in_i = (top.pad_in_i & ~(uint32_t(1) << HB_RWDS_BIT)) |
                   (uint32_t(value ? 1 : 0) << HB_RWDS_BIT);
}

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
    set_hb_dq_in(top_, 0);
    set_hb_rwds_in(top_, false);
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
    set_hb_dq_in(top_, 0);
    set_hb_rwds_in(top_, false);
}

void Hyperram::sample_command() {
    if (!hb_dq_oe(top_)) {
        throw std::runtime_error("HyperRAM command ended early");
    }

    command_ = (command_ << 8) | hb_dq_out(top_);
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

    set_hb_dq_in(top_, memory_.read_byte(byte_address));
    set_hb_rwds_in(top_, rising_edge);

    if (!rising_edge) {
        address_ += 2;
    }
}

void Hyperram::sample_write_data(bool rising_edge) {
    uint32_t byte_address = address_ + (rising_edge ? 1 : 0);

    if (!memory_.in_range(byte_address)) {
        throw std::runtime_error("HyperRAM write is out of range");
    }

    if (!hb_rwds_out(top_)) {
        memory_.write_byte(byte_address, hb_dq_out(top_));
    }

    if (!rising_edge) {
        address_ += 2;
    }
}

void Hyperram::update() {
    bool clock = hb_ck(top_);
    uint8_t chip_select = hb_cs(top_) & 3;
    int chip = selected_chip(chip_select);

    if (!hb_reset_n(top_) || chip < 0) {
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
        if (!hb_dq_oe(top_)) {
            phase_ = Phase::Read;
            turnaround_edges_ = TURNAROUND_EDGES;
        } else if (hb_rwds_oe(top_)) {
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

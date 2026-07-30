#include "hyperram.hpp"

#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>

#include "Vfriscv_soc.h"

namespace {

constexpr uint64_t READ_TRANSACTION = uint64_t(1) << 47;
constexpr uint64_t REGISTER_SPACE = uint64_t(1) << 46;
constexpr uint64_t ADDRESS_UPPER_MASK = (uint64_t(1) << 29) - 1;

constexpr unsigned HB_DQ_LSB   = 13;
constexpr unsigned HB_RWDS_BIT = 21;
constexpr unsigned HB_CK_BIT   = 22;
constexpr unsigned HB_CS_BIT   = 23;
constexpr unsigned HB_RST_BIT  = 24;

unsigned env_unsigned(const char* name, unsigned fallback) {
    const char* text = std::getenv(name);

    return text != nullptr ? unsigned(std::strtoul(text, nullptr, 0)) : fallback;
}

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

// PA23 carries HB_CS0_N, active low
bool hb_cs_active(const Vfriscv_soc& top) {
    return ((top.pad_out_o >> HB_CS_BIT) & 1) == 0;
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

}  // namespace

HyperramTiming HyperramTiming::from_env() {
    HyperramTiming timing;

    timing.latency       = env_unsigned("FRISCV_HRAM_LATENCY", timing.latency);
    timing.fixed         = env_unsigned("FRISCV_HRAM_FIXED", 0) != 0;
    timing.refresh_every = env_unsigned("FRISCV_HRAM_REFRESH_EVERY", 0);
    timing.t_csm         = env_unsigned("FRISCV_HRAM_TCSM", 0);
    timing.strict        = env_unsigned("FRISCV_HRAM_STRICT", 1) != 0;

    if (timing.latency < 2) {
        throw std::runtime_error("FRISCV_HRAM_LATENCY must be at least 2");
    }

    return timing;
}

Hyperram::Hyperram(Vfriscv_soc& top)
    : top_(top), memory_(0, MEMORY_SIZE), timing_(HyperramTiming::from_env()) {
    set_hb_dq_in(top_, 0);
    set_hb_rwds_in(top_, false);
}

void Hyperram::begin_transaction() {
    phase_ = Phase::Command;
    command_ = 0;
    command_bytes_ = 0;
    turnaround_edges_ = 0;
    wait_edges_ = 0;
    cs_edges_ = 0;
    ++transactions_;

    // Devices raise RWDS through the command phase on a refresh collision;
    // the controller doubles t_latency_access from it
    additional_latency_ = timing_.fixed ||
                          (timing_.refresh_every != 0 &&
                           transactions_ % timing_.refresh_every == 0);

    set_hb_rwds_in(top_, additional_latency_);
}

void Hyperram::end_transaction() {
    phase_ = Phase::Idle;
    set_hb_dq_in(top_, 0);
    set_hb_rwds_in(top_, false);
}

void Hyperram::violation(const char* what, unsigned expected, unsigned actual) {
    std::string message = "HyperRAM timing violation: " + std::string(what) +
                          ", expected " + std::to_string(expected) +
                          " clock edges, saw " + std::to_string(actual);

    if (timing_.strict) {
        throw std::runtime_error(message);
    }

    std::fprintf(stderr, "warning: %s\n", message.c_str());
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

    read_ = (command_ & READ_TRANSACTION) != 0;

    uint32_t word_address = uint32_t((command_ >> 16) & ADDRESS_UPPER_MASK);
    word_address = (word_address << 3) | uint32_t(command_ & 7);
    address_ = word_address << 1;

    if (!memory_.in_range(address_)) {
        throw std::runtime_error("HyperRAM address is out of range");
    }

    set_hb_rwds_in(top_, false);
    phase_ = Phase::Wait;
}

void Hyperram::check_turnaround() {
    unsigned expected = timing_.latency_edges(additional_latency_);

    // Late only wastes bandwidth; early samples data that is not driven yet
    if (wait_edges_ < expected) {
        violation("bus turned around before the initial latency elapsed",
                  expected, wait_edges_);
    }
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

    if (!hb_reset_n(top_) || !hb_cs_active(top_)) {
        end_transaction();
        clock_ = clock;
        return;
    }

    if (phase_ == Phase::Idle) {
        begin_transaction();
    }

    if (clock == clock_) {
        return;
    }

    clock_ = clock;
    ++cs_edges_;

    // Real silicon loses data if CS# stays low past t_CSM
    if (timing_.t_csm != 0 && cs_edges_ == 2 * timing_.t_csm + 1) {
        violation("CS# held low past t_CSM", 2 * timing_.t_csm, cs_edges_);
    }

    if (phase_ == Phase::Command) {
        sample_command();
        return;
    }

    if (phase_ == Phase::Wait) {
        ++wait_edges_;

        // Output enables change one clock before the first data beat.
        if (!hb_dq_oe(top_)) {
            if (!read_) {
                throw std::runtime_error(
                    "HyperRAM controller released DQ during a write");
            }

            check_turnaround();
            phase_ = Phase::Read;
            turnaround_edges_ = TURNAROUND_EDGES;
        } else if (hb_rwds_oe(top_)) {
            if (read_) {
                throw std::runtime_error(
                    "HyperRAM controller drove RWDS during a read");
            }

            check_turnaround();
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

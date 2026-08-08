#pragma once

#include <cstdint>
#include <vector>

#include "paged_mem.hpp"

#include "dut.hpp"

// FRISCV_HRAM_<FIELD> overrides each field, so sweeps need no rebuild
struct HyperramTiming {
    unsigned latency = 6;
    bool     fixed = false;
    unsigned refresh_every = 0;
    unsigned t_csm = 0;
    bool     strict = true;

    static HyperramTiming from_env();

    // Edges from the last command byte to the controller's turnaround,
    // measured against pulp_hyperbus for t_latency_access 3..7
    unsigned latency_edges(bool additional) const {
        return 2 * (latency << (additional ? 1 : 0)) - 3;
    }
};

class Hyperram {
  public:
    explicit Hyperram(Dut& top);

    void update();
    void preload(uint32_t address, const std::vector<uint8_t>& data);

  private:
    enum class Phase {
        Idle,
        Command,
        Wait,
        Read,
        Write,
    };

    static constexpr uint32_t MEMORY_SIZE = 0x10000000;
    static constexpr unsigned COMMAND_BYTES = 6;
    static constexpr unsigned TURNAROUND_EDGES = 2;

    void begin_transaction();
    void end_transaction();
    void sample_command();
    void finish_command();
    void check_turnaround();
    void violation(const char* what, unsigned expected, unsigned actual);
    void drive_read_data(bool rising_edge);
    void sample_write_data(bool rising_edge);

    Dut& top_;
    PagedMem memory_;
    HyperramTiming timing_;
    Phase phase_ = Phase::Idle;
    uint64_t command_ = 0;
    uint32_t address_ = 0;
    unsigned command_bytes_ = 0;
    unsigned turnaround_edges_ = 0;
    unsigned wait_edges_ = 0;
    unsigned cs_edges_ = 0;
    uint64_t transactions_ = 0;
    bool additional_latency_ = false;
    bool read_ = false;
    bool clock_ = false;
};

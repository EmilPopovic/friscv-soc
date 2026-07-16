#pragma once

#include <cstdint>

#include "paged_mem.hpp"

class Vfriscv_soc;

class Hyperram {
  public:
    explicit Hyperram(Vfriscv_soc& top);

    void update();

  private:
    enum class Phase {
        Idle,
        Command,
        Wait,
        Read,
        Write,
    };

    static constexpr uint32_t MEMORY_SIZE = 0x01000000;
    static constexpr unsigned COMMAND_BYTES = 6;
    static constexpr unsigned TURNAROUND_EDGES = 2;

    void begin_transaction(uint8_t chip);
    void end_transaction();
    void sample_command();
    void finish_command();
    void drive_read_data(bool rising_edge);
    void sample_write_data(bool rising_edge);

    Vfriscv_soc& top_;
    PagedMem memory_;
    Phase phase_ = Phase::Idle;
    uint64_t command_ = 0;
    uint32_t address_ = 0;
    unsigned command_bytes_ = 0;
    unsigned turnaround_edges_ = 0;
    uint8_t chip_ = 0;
    bool clock_ = false;
};

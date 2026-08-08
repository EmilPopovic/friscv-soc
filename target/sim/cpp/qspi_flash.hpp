#pragma once

#include <cstdint>
#include <vector>

#include "paged_mem.hpp"

#include "dut.hpp"

// SPI NOR on QSPI0 CS0. JEDEC ID and single-bit reads, mode 0; no quad, no writes.
class QspiFlash {
  public:
    explicit QspiFlash(Dut& top);

    void update();
    void preload(uint32_t address, const std::vector<uint8_t>& data);

  private:
    enum class Phase {
        Command,
        Address,
        Read,
        Id,
    };

    static constexpr uint32_t MEMORY_SIZE = 0x1000000;  // 16 MB, 24-bit addresses

    void begin_transaction();
    void sample_bit(bool mosi);
    void drive_bit();
    void finish_byte();

    Dut& top_;
    PagedMem memory_;
    Phase phase_ = Phase::Command;
    uint8_t shift_in_ = 0;
    uint8_t shift_out_ = 0;
    unsigned bit_ = 0;
    unsigned address_bytes_ = 0;
    uint32_t address_ = 0;
    uint8_t command_ = 0;
    bool clock_ = false;
    bool selected_ = false;
};

#pragma once

#include <cstdint>
#include "paged_mem.hpp"
#include "bus.hpp"

class MemModel : public BusDevice {
  private:
    PagedMem* mem;  // Byte-addressible pool

    // Internal control
    bool     in_flight;
    uint8_t  in_flight_size;
    uint32_t in_flight_addr;
    uint32_t in_flight_wdata;
    bool     in_flight_w_en;
    bool     in_flight_r_en;
    bool     in_flight_burst_en;

    // Wait cycles config
    //  >=0 - deterministic wait for wait_cycles
    //  -1  - random wait between MIN_RAND_WAIT and MAX_RAND_WAIT cycles
    //  -2  - random wait between 0 and MAX_RAND_WAIT cycles
    int wait_cycles;
    int current_wait;

    bool     addr_misaligned(uint32_t addr, int size);
    int      shift_for(uint32_t addr, int size);
    uint32_t mask_for(int size);
    uint32_t read_word_aligned(uint32_t addr);
    uint32_t read(uint32_t addr, int size);
    void     write(uint32_t addr, int size, uint32_t data);
    int      next_wait_cycles();

  public:
    MemModel(PagedMem* mem, int wait_cycles);
    void cycle(uint8_t size, uint32_t offset, uint32_t wdata,
               bool w_en, bool r_en, bool burst_en) override;
};
  
// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>

#include "mem_model.hpp"
#include <random>

#define RAND_WAIT_MODE_RANGE (-1)
#define RAND_WAIT_MODE_MAX   (-2)

#define MIN_RAND_WAIT (1)
#define MAX_RAND_WAIT (3)

#define SIZE_BYTE (0b00)
#define SIZE_HALF (0b01)
#define SIZE_WORD (0b10)

MemModel::MemModel(PagedMem* mem, int wait_cycles) {
    this->mem = mem;
    this->wait_cycles = wait_cycles;

    // Reset internal control
    in_flight = false;
    in_flight_size = 0;
    in_flight_addr = 0;
    in_flight_wdata = 0;
    in_flight_w_en = false;
    in_flight_r_en = false;
    in_flight_burst_en = false;
    current_wait = 0;

    // Reset output interface
    rdata = 0;
    wait = false;
    beat_valid = false;
    err = false;
}

bool MemModel::addr_misaligned(uint32_t addr, int size) {
    if (size == SIZE_WORD) {
        return addr & 0b11;
    } else if (size == SIZE_HALF) {
        return addr & 0b1;
    }
    return false;
}

int MemModel::shift_for(uint32_t addr, int size) {
    if (size == SIZE_HALF) {
        return (addr & 0b10) ? 16 : 0;
    } else if (size == SIZE_BYTE) {
        return (addr & 0b11) * 8;
    }
    return 0;
}

uint32_t MemModel::mask_for(int size) {
    if (size == SIZE_HALF) {
        return 0xFFFF;
    } else if (size == SIZE_BYTE) {
        return 0xFF;
    }
    return 0xFFFFFFFF;
}

uint32_t MemModel::read_word_aligned(uint32_t addr) {
    uint32_t word_aligned_addr = addr & ~0b11;

    uint8_t byte0 = mem->read_byte(word_aligned_addr+0);
    uint8_t byte1 = mem->read_byte(word_aligned_addr+1);
    uint8_t byte2 = mem->read_byte(word_aligned_addr+2);
    uint8_t byte3 = mem->read_byte(word_aligned_addr+3);

    return (byte3 << 24) | (byte2 << 16) | (byte1 << 8) | (byte0 << 0);
}

uint32_t MemModel::read(uint32_t addr, int size) {
    (void)size;
    return read_word_aligned(addr);
}

void MemModel::write(uint32_t addr, int size, uint32_t data) {
    uint32_t word_aligned_addr = addr & ~0b11;
    uint32_t lane_mask = mask_for(size) << shift_for(addr, size);

    uint32_t word_aligned = read_word_aligned(addr);
    word_aligned &= ~lane_mask;
    word_aligned |= data & lane_mask;

    mem->write_byte(word_aligned_addr+0, (word_aligned >> 0) & 0xFF);
    mem->write_byte(word_aligned_addr+1, (word_aligned >> 8) & 0xFF);
    mem->write_byte(word_aligned_addr+2, (word_aligned >> 16) & 0xFF);
    mem->write_byte(word_aligned_addr+3, (word_aligned >> 24) & 0xFF);
}

int MemModel::next_wait_cycles() {
    static std::mt19937 gen(std::random_device{}());

    if (wait_cycles >= 0) {
        return wait_cycles;
    } else if (wait_cycles == RAND_WAIT_MODE_MAX) {
        std::uniform_int_distribution<int> dist(0, MAX_RAND_WAIT);
        return dist(gen);
    } else if (wait_cycles == RAND_WAIT_MODE_RANGE) {
        std::uniform_int_distribution<int> dist(MIN_RAND_WAIT, MAX_RAND_WAIT);
        return dist(gen);
    } else {
        return 0;
    }
}

void MemModel::cycle(uint8_t size, uint32_t offset, uint32_t wdata,
                     bool w_en, bool r_en, bool burst_en) {
    err = false;
    beat_valid = false;

    if (in_flight && current_wait != 0) {
        // This is a wait cycle of an already issued transfer
        wait = true;
        current_wait--;
    } else if (current_wait == 0) {
        // A transfer just finished or this is an idle cycle

        if (in_flight) {
            // This is the last cycle of a long transfer
            in_flight = false;
            wait = false;

            if (in_flight_r_en) {
                // The finishing transfer was a read
                in_flight_r_en = false;
                rdata = read(in_flight_addr, in_flight_size);
            } else if (in_flight_w_en) {
                // The finishing transfer was a write
                in_flight_w_en = false;
                write(in_flight_addr, in_flight_size, in_flight_wdata);
            }
        } else if (r_en || w_en) {
            // The bus delivers offsets instead of absolute addresses
            uint32_t addr = mem->base_addr() + offset;

            if (!mem->in_range(addr) || addr_misaligned(addr, size)) {
                // End transfer immediately if address not in range or misaligned
                err = true;
                wait = false;
                return;
            }

            current_wait = next_wait_cycles();
            if (current_wait == 0) {
                // This is a single-cycle transfer
                if (r_en) {
                    rdata = read(addr, size);
                } else if (w_en) {
                    write(addr, size, wdata);
                }
                wait = false;
                in_flight = false;
            } else {
                wait = true;
                in_flight = true;
                in_flight_size = size;
                in_flight_addr = addr;
                in_flight_wdata = wdata;
                in_flight_w_en = w_en;
                in_flight_r_en = r_en;
                in_flight_burst_en = burst_en;
            }
        }
    }
}

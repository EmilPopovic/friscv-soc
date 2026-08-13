// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>

#pragma once

#include <cstdint>
#include <vector>

class BusDevice {
  public:
    // Output interface
    uint32_t rdata      = 0;
    bool     wait       = false;
    bool     beat_valid = false;
    bool     err        = false;

    virtual ~BusDevice() = default;
    virtual void cycle(uint8_t size, uint32_t offset, uint32_t wdata,
                       bool w_en, bool r_en, bool burst_en) = 0;
};

class BusRouter : public BusDevice {
  public:
    void map(uint32_t base, uint32_t size, BusDevice* dev);
    void cycle(uint8_t size, uint32_t offset, uint32_t wdata,
               bool w_en, bool r_en, bool burst_en) override;
  private:
    struct Mapping {
        uint32_t base;
        uint32_t size;
        BusDevice* dev;
    };
    std::vector<Mapping> address_map;
    BusDevice* owner = nullptr;
    uint32_t owner_base = 0;
};

class SinkDevice : public BusDevice {
  public:
    void cycle(uint8_t size, uint32_t offset, uint32_t wdata,
               bool w_en, bool r_en, bool burst_en) override {
        if (w_en) last_write = wdata;
    };
    uint32_t get_last_write() const { return last_write; }
  private:
    uint32_t last_write = 0;
};

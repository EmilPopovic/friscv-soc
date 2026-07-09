#pragma once

#include "bus.hpp"

class ClintModel : public BusDevice {
  public:
    void cycle(uint8_t size, uint32_t offset, uint32_t wdata,
               bool w_en, bool r_en, bool burst_en) override;
};

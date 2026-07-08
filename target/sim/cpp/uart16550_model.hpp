#pragma once

#include "bus.hpp"

class Uart16550Model : public BusDevice {
  private:
    uint8_t rbr = 0;     // Receiver Buffer Register (read-only)
    uint8_t thr = 0;     // Transmitter Holding Register (write-only)
    uint8_t ier = 0;     // Interrupt Enable Register
    uint8_t iir = 0x01;  // Interrupt Identification Register (read-only)
    uint8_t lcr = 0;     // Line Control Register
    uint8_t mcr = 0;     // Modem Control Register
    uint8_t lsr = 0x60;  // Line Status Register (read-only)
    uint8_t msr = 0;     // Modem Status Register (read-only)
    uint8_t scr = 0;     // Scratch Register
  public:
    Uart16550Model();
    void cycle(uint8_t size, uint32_t addr, uint32_t wdata,
               bool w_en, bool r_en, bool burst_en) override;
};

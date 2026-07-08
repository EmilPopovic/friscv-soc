#include "uart16550_model.hpp"

Uart16550Model::Uart16550Model() {
    // Initialize registers to default values
    rbr = 0;
    thr = 0;
    ier = 0;
    iir = 0x01;  // No interrupt pending
    lcr = 0;
    mcr = 0;
    lsr = 0x60;  // Transmitter empty and line idle
    msr = 0;
    scr = 0;
}

void Uart16550Model::cycle(uint8_t size, uint32_t addr, uint32_t wdata,
                      bool w_en, bool r_en, bool burst_en) {
    // TODO
}

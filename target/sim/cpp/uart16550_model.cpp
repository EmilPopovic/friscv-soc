// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>

#include "uart16550_model.hpp"

#include <cstdio>

#define REG_RBR_THR_DLL (0)
#define REG_IER_DLM     (1)
#define REG_IIR_FCR     (2)
#define REG_LCR         (3)
#define REG_MCR         (4)
#define REG_LSR         (5)
#define REG_MSR         (6)
#define REG_SCR         (7)

#define IIR_NO_INT_PENDING (0x01)
#define LSR_THRE_TEMT      (0x60)

// TX-only
void Uart16550Model::cycle(uint8_t size, uint32_t offset, uint32_t wdata,
                           bool w_en, bool r_en, bool burst_en) {
    (void)size;
    (void)burst_en;

    rdata      = 0;
    wait       = false;
    beat_valid = false;
    err        = false;

    if (!w_en && !r_en) return;

    uint32_t reg  = (offset >> 2) & 0x7;
    uint8_t  byte = wdata & 0xFF;

    if (w_en) {
        switch (reg) {
            case REG_RBR_THR_DLL:
                if (dlab()) {
                    dll = byte;
                } else {
                    std::fputc(byte, stdout);
                    std::fflush(stdout);
                }
                break;
            case REG_IER_DLM: if (dlab()) dlm = byte; else ier = byte; break;
            case REG_IIR_FCR: break;
            case REG_LCR:     lcr = byte; break;
            case REG_MCR:     mcr = byte; break;
            case REG_SCR:     scr = byte; break;
            default:          break;
        }
    } else {
        switch (reg) {
            case REG_RBR_THR_DLL: rdata = dlab() ? dll : 0; break;
            case REG_IER_DLM:     rdata = dlab() ? dlm : ier; break;
            case REG_IIR_FCR:     rdata = IIR_NO_INT_PENDING; break;
            case REG_LCR:         rdata = lcr; break;
            case REG_MCR:         rdata = mcr; break;
            case REG_LSR:         rdata = LSR_THRE_TEMT; break;
            case REG_MSR:         rdata = 0; break;
            case REG_SCR:         rdata = scr; break;
        }
    }
}

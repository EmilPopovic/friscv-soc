// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>

#pragma once

#include <cstdint>

#include "Vvernii_soc_sim.h"

using Dut = Vvernii_soc_sim;

namespace dut {

inline void clear_inputs(Dut& top) {
    top.boot_sel_i = 0;
    top.gpio_a_i = 0;
    top.qspi0_sd_i = 0;
}

inline void set_boot_sel(Dut& top, unsigned value) {
    top.boot_sel_i = uint8_t(value);
}

inline bool jtag_tdo(const Dut& top) {
    return top.jtag_tdo_oe_o != 0 && top.jtag_tdo_o != 0;
}

inline bool qspi_sck(const Dut& top) {
    return top.qspi0_sck_o != 0;
}

inline bool qspi_selected(const Dut& top, unsigned cs) {
    return ((top.qspi0_cs_o >> cs) & 1) == 0;
}

inline bool qspi_mosi(const Dut& top) {
    return (top.qspi0_sd_o & 1) != 0;
}

inline void qspi_miso(Dut& top, bool value) {
    top.qspi0_sd_i = uint8_t((top.qspi0_sd_i & ~0x2u) | (value ? 0x2u : 0x0u));
}

}  // namespace dut

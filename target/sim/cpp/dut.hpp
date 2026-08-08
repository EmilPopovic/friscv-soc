#pragma once

#include <cstdint>

#include "Vfriscv_soc_sim.h"

using Dut = Vfriscv_soc_sim;

namespace dut {

inline void clear_inputs(Dut& top) {
    top.i_strap = 0;
    top.i_gpio = 0;
    top.i_qspi_sd = 0;
}

inline void set_strap(Dut& top, unsigned bit) {
    top.i_strap |= uint32_t(1) << bit;
}

inline bool qspi_sck(const Dut& top) {
    return top.o_qspi_sck != 0;
}

inline bool qspi_selected(const Dut& top) {
    return (top.o_qspi_cs & 1) == 0;
}

inline bool qspi_mosi(const Dut& top) {
    return (top.o_qspi_sd & 1) != 0;
}

inline void qspi_miso(Dut& top, bool value) {
    top.i_qspi_sd = uint8_t((top.i_qspi_sd & ~0x2u) | (value ? 0x2u : 0x0u));
}

}  // namespace dut

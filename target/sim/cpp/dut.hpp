#pragma once

#include <cstdint>

#ifdef FRISCV_TB_CHIP
#include "Vfriscv_chip_soc.h"
using Dut = Vfriscv_chip_soc;
#else
#include "Vfriscv_soc_sim.h"
using Dut = Vfriscv_soc_sim;
#endif

namespace dut {

constexpr unsigned QSPI_SD_LSB  = 5;   // PA5..PA8 = IO0..IO3
constexpr unsigned QSPI_SCK_BIT = 9;
constexpr unsigned QSPI_CS0_BIT = 10;
constexpr unsigned QSPI_MISO_BIT = QSPI_SD_LSB + 1;

inline void clear_inputs(Dut& top) {
#ifdef FRISCV_TB_CHIP
    top.pad_in_i = 0;
#else
    top.i_strap = 0;
    top.i_gpio = 0;
    top.i_qspi_sd = 0;
#endif
}

inline void set_strap(Dut& top, unsigned bit) {
#ifdef FRISCV_TB_CHIP
    top.pad_in_i |= uint32_t(1) << bit;
#else
    top.i_strap |= uint32_t(1) << bit;
#endif
}

inline bool qspi_sck(const Dut& top) {
#ifdef FRISCV_TB_CHIP
    return ((top.pad_out_o >> QSPI_SCK_BIT) & 1) != 0;
#else
    return top.o_qspi_sck != 0;
#endif
}

inline bool qspi_selected(const Dut& top) {
#ifdef FRISCV_TB_CHIP
    return ((top.pad_out_o >> QSPI_CS0_BIT) & 1) == 0;
#else
    return (top.o_qspi_cs & 1) == 0;
#endif
}

inline bool qspi_mosi(const Dut& top) {
#ifdef FRISCV_TB_CHIP
    return ((top.pad_out_o >> QSPI_SD_LSB) & 1) != 0;
#else
    return (top.o_qspi_sd & 1) != 0;
#endif
}

inline void qspi_miso(Dut& top, bool value) {
#ifdef FRISCV_TB_CHIP
    top.pad_in_i = (top.pad_in_i & ~(uint32_t(1) << QSPI_MISO_BIT)) |
                   (uint32_t(value ? 1 : 0) << QSPI_MISO_BIT);
#else
    top.i_qspi_sd = uint8_t((top.i_qspi_sd & ~0x2u) | (value ? 0x2u : 0x0u));
#endif
}

}  // namespace dut

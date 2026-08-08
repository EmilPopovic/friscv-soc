#include "soc_memory.hpp"

#include <stdexcept>

#ifdef FRISCV_TB_CHIP
#include "Vfriscv_chip_soc___024root.h"
using DutRoot = Vfriscv_chip_soc___024root;
#else
#include "Vfriscv_soc_sim___024root.h"
using DutRoot = Vfriscv_soc_sim___024root;
#endif

#include "elf_loader.hpp"

namespace {

#ifndef FRISCV_SOC_SRAM_SIZE_BYTES
#define FRISCV_SOC_SRAM_SIZE_BYTES 0x2000
#endif

// friscv_ocm_llc splits the OCM over WAYS equally sized tc_sram macros. A word
// address is [WAY_SEL, WAY_ADDR], so way i holds the i-th contiguous slice of
// the region rather than every WAYS-th word.
constexpr unsigned WAYS = 4;
constexpr uint32_t WAY_WORDS = FRISCV_SOC_SRAM_SIZE_BYTES / (WAYS * 4);

static_assert(WAY_WORDS * WAYS * 4 == FRISCV_SOC_SRAM_SIZE_BYTES,
              "SRAM size must split evenly over the OCM ways");

uint32_t& sram_word(Dut& top, uint32_t index) {
    DutRoot& root = *top.rootp;

#ifdef FRISCV_TB_CHIP
    uint32_t* const way_words[WAYS] = {
        &root.friscv_chip_soc__DOT__i_friscv_soc__DOT__friscv_mem_hub__DOT__ocm_llc__DOT__gen_ways__BRA__0__KET____DOT__way_sram__DOT__sram[0],
        &root.friscv_chip_soc__DOT__i_friscv_soc__DOT__friscv_mem_hub__DOT__ocm_llc__DOT__gen_ways__BRA__1__KET____DOT__way_sram__DOT__sram[0],
        &root.friscv_chip_soc__DOT__i_friscv_soc__DOT__friscv_mem_hub__DOT__ocm_llc__DOT__gen_ways__BRA__2__KET____DOT__way_sram__DOT__sram[0],
        &root.friscv_chip_soc__DOT__i_friscv_soc__DOT__friscv_mem_hub__DOT__ocm_llc__DOT__gen_ways__BRA__3__KET____DOT__way_sram__DOT__sram[0],
    };
#else
    uint32_t* const way_words[WAYS] = {
        &root.friscv_soc_sim__DOT__i_friscv_soc__DOT__friscv_mem_hub__DOT__ocm_llc__DOT__gen_ways__BRA__0__KET____DOT__way_sram__DOT__sram[0],
        &root.friscv_soc_sim__DOT__i_friscv_soc__DOT__friscv_mem_hub__DOT__ocm_llc__DOT__gen_ways__BRA__1__KET____DOT__way_sram__DOT__sram[0],
        &root.friscv_soc_sim__DOT__i_friscv_soc__DOT__friscv_mem_hub__DOT__ocm_llc__DOT__gen_ways__BRA__2__KET____DOT__way_sram__DOT__sram[0],
        &root.friscv_soc_sim__DOT__i_friscv_soc__DOT__friscv_mem_hub__DOT__ocm_llc__DOT__gen_ways__BRA__3__KET____DOT__way_sram__DOT__sram[0],
    };
#endif

    if (index >= WAYS * WAY_WORDS) {
        throw std::runtime_error("SRAM preload past the end of the OCM");
    }

    return way_words[index / WAY_WORDS][index % WAY_WORDS];
}

void write_byte(Dut& top, uint32_t offset, uint8_t data) {
    uint32_t& word = sram_word(top, offset / 4);
    unsigned shift = (offset & 3) * 8;

    word = (word & ~(0xffu << shift)) | (uint32_t(data) << shift);
}

}  // namespace

void preload_sram(Dut& top, const ElfImage& image,
                  uint32_t sram_base) {
    for (const ElfSegment& segment : image.segments) {
        uint32_t offset = segment.address - sram_base;

        for (uint8_t byte : segment.data) {
            write_byte(top, offset, byte);
            ++offset;
        }
    }
}

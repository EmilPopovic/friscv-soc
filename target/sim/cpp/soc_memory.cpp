// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>
// Matej Jurasić <matej.jurasic@cappig.dev>

#include "soc_memory.hpp"

#include <stdexcept>

#include "Vvernii_soc_sim___024root.h"

using DutRoot = Vvernii_soc_sim___024root;

#include "elf_loader.hpp"

namespace {

#ifndef VERNII_SOC_SRAM_SIZE_BYTES
#define VERNII_SOC_SRAM_SIZE_BYTES 0x2000
#endif

#ifndef VERNII_SOC_OCM_ONLY
#define VERNII_SOC_OCM_ONLY 0
#endif

constexpr uint32_t OCM_WORDS = VERNII_SOC_SRAM_SIZE_BYTES / 4;

static_assert(OCM_WORDS * 4 == VERNII_SOC_SRAM_SIZE_BYTES,
              "SRAM size must be a whole number of words");

#if VERNII_SOC_OCM_ONLY

uint32_t& sram_word(Dut& top, uint32_t index) {
    DutRoot& root = *top.rootp;

    if (index >= OCM_WORDS) {
        throw std::runtime_error("SRAM preload past the end of the OCM");
    }

    return root.vernii_soc_sim__DOT__i_vernii_soc__DOT__i_mem_hub__DOT__gen_ocm_sram__DOT__ocm_sram__DOT__sram[index];
}

#else

// friscv_ocm_llc splits the OCM over WAYS equally sized tc_sram macros. A word
// address is [WAY_SEL, WAY_ADDR], so way i holds the i-th contiguous slice of
// the region rather than every WAYS-th word.
constexpr unsigned WAYS = 4;
constexpr uint32_t WAY_WORDS = OCM_WORDS / WAYS;

static_assert(WAY_WORDS * WAYS == OCM_WORDS,
              "SRAM size must split evenly over the OCM ways");

uint32_t& sram_word(Dut& top, uint32_t index) {
    DutRoot& root = *top.rootp;

    uint32_t* const way_words[WAYS] = {
        &root.vernii_soc_sim__DOT__i_vernii_soc__DOT__i_mem_hub__DOT__gen_ocm_llc__DOT__ocm_llc__DOT__gen_ways__BRA__0__KET____DOT__way_sram__DOT__sram[0],
        &root.vernii_soc_sim__DOT__i_vernii_soc__DOT__i_mem_hub__DOT__gen_ocm_llc__DOT__ocm_llc__DOT__gen_ways__BRA__1__KET____DOT__way_sram__DOT__sram[0],
        &root.vernii_soc_sim__DOT__i_vernii_soc__DOT__i_mem_hub__DOT__gen_ocm_llc__DOT__ocm_llc__DOT__gen_ways__BRA__2__KET____DOT__way_sram__DOT__sram[0],
        &root.vernii_soc_sim__DOT__i_vernii_soc__DOT__i_mem_hub__DOT__gen_ocm_llc__DOT__ocm_llc__DOT__gen_ways__BRA__3__KET____DOT__way_sram__DOT__sram[0],
    };

    if (index >= OCM_WORDS) {
        throw std::runtime_error("SRAM preload past the end of the OCM");
    }

    return way_words[index / WAY_WORDS][index % WAY_WORDS];
}

#endif

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

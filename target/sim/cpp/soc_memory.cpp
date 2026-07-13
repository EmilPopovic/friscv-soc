#include "soc_memory.hpp"

#include "Vfriscv_soc.h"
#include "Vfriscv_soc___024root.h"

#include "elf_loader.hpp"

namespace {

void write_byte(Vfriscv_soc& top, uint32_t offset, uint8_t data) {
    auto& sram = top.rootp->friscv_soc__DOT__sram__DOT__sram;
    uint32_t& word = sram[offset / 4];
    unsigned shift = (offset & 3) * 8;

    word = (word & ~(0xffu << shift)) | (uint32_t(data) << shift);
}

}  // namespace

void preload_sram(Vfriscv_soc& top, const ElfImage& image,
                  uint32_t sram_base) {
    for (const ElfSegment& segment : image.segments) {
        uint32_t offset = segment.address - sram_base;

        for (uint8_t byte : segment.data) {
            write_byte(top, offset, byte);
            ++offset;
        }
    }
}

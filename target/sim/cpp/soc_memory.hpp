#ifndef SOC_MEMORY_HPP
#define SOC_MEMORY_HPP

#include <cstdint>

#include "dut.hpp"
struct ElfImage;

void preload_sram(Dut& top, const ElfImage& image,
                  uint32_t sram_base);

#endif

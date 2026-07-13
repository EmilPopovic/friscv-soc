#ifndef SOC_MEMORY_HPP
#define SOC_MEMORY_HPP

#include <cstdint>

class Vfriscv_soc;
struct ElfImage;

void preload_sram(Vfriscv_soc& top, const ElfImage& image,
                  uint32_t sram_base);

#endif

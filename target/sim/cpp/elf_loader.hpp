#pragma once

#include <cstdint>
#include <vector>

class PagedMem;

struct ElfSegment {
    uint32_t address;
    bool executable;
    std::vector<uint8_t> data;
};

struct ElfImage {
    uint16_t machine;
    uint32_t entry;
    std::vector<ElfSegment> segments;
};

ElfImage read_elf(const char* path);
uint32_t load_elf(const char* path, PagedMem* memory);

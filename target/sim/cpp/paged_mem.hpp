#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <vector>

// Byte-addressible memory pool with page-granular lazy allocation.
class PagedMem {
  public:
    static constexpr uint32_t PAGE_BITS = 12;
    static constexpr uint32_t PAGE_SIZE = 1u << PAGE_BITS;

    PagedMem(uint32_t base_addr, uint32_t size);

    bool     in_range(uint32_t addr) const;
    uint8_t  read_byte(uint32_t addr);
    void     write_byte(uint32_t addr, uint8_t data);

    uint32_t base_addr() const { return base; }
    uint32_t size() const { return mem_size; }

  private:
    using Page = std::array<uint8_t, PAGE_SIZE>;

    uint32_t base;
    uint32_t mem_size;
    std::vector<std::unique_ptr<Page>> pages;

    uint8_t* byte_ptr(uint32_t addr);
};

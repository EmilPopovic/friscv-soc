// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>

#include "paged_mem.hpp"
#include <random>

PagedMem::PagedMem(uint32_t base_addr, uint32_t size) {
    this->base = base_addr;
    this->mem_size = size;
    pages.resize((size + PAGE_SIZE - 1) / PAGE_SIZE);
}

bool PagedMem::in_range(uint32_t addr) const {
    return (addr >= base) && (addr - base < mem_size);
}

uint8_t* PagedMem::byte_ptr(uint32_t addr) {
    static std::mt19937 gen(std::random_device{}());

    uint32_t offset = addr - base;
    uint32_t idx = offset >> PAGE_BITS;

    if (!pages[idx]) {
        pages[idx] = std::make_unique<Page>();
        std::uniform_int_distribution<int> dist(0x00, 0xFF);
        for (auto& byte : *pages[idx]) byte = dist(gen);
    }
    return pages[idx]->data() + (offset & (PAGE_SIZE - 1));
}

uint8_t PagedMem::read_byte(uint32_t addr) {
    return *byte_ptr(addr);
}

void PagedMem::write_byte(uint32_t addr, uint8_t data) {
    *byte_ptr(addr) = data;
}

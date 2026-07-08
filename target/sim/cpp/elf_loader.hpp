#pragma once

#include <cstdint>
#include "paged_mem.hpp"

uint32_t load_elf(const char* path, PagedMem* mem);

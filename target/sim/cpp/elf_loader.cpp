// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
// Emil Popović <mail@emilpopovic.me>

#include "elf_loader.hpp"

#include <elf.h>

#include <algorithm>
#include <cstring>
#include <fstream>
#include <iterator>
#include <limits>
#include <stdexcept>

#include "paged_mem.hpp"

namespace {

using File = std::vector<uint8_t>;

File read_file(const char* path) {
    std::ifstream stream(path, std::ios::binary);

    if (!stream) {
        throw std::runtime_error("cannot open ELF");
    }

    return File(std::istreambuf_iterator<char>(stream),
                std::istreambuf_iterator<char>());
}

void check_range(size_t offset, size_t size, size_t file_size) {
    if (offset > file_size || size > file_size - offset) {
        throw std::runtime_error("truncated ELF");
    }
}

template <typename T>
T read_at(const File& file, size_t offset) {
    check_range(offset, sizeof(T), file.size());

    T value = {};
    std::memcpy(&value, file.data() + offset, sizeof(value));
    return value;
}

void validate(const Elf32_Ehdr& header) {
    if (std::memcmp(header.e_ident, ELFMAG, SELFMAG) != 0) {
        throw std::runtime_error("not an ELF");
    }

    if (header.e_ident[EI_CLASS] != ELFCLASS32) {
        throw std::runtime_error("not ELF32");
    }

    if (header.e_ident[EI_DATA] != ELFDATA2LSB) {
        throw std::runtime_error("not little-endian");
    }

    if (header.e_phentsize < sizeof(Elf32_Phdr)) {
        throw std::runtime_error("invalid ELF program header");
    }
}

ElfSegment read_segment(const File& file, const Elf32_Phdr& header) {
    if (header.p_filesz > header.p_memsz) {
        throw std::runtime_error("invalid ELF segment size");
    }

    check_range(header.p_offset, header.p_filesz, file.size());

    ElfSegment segment;
    segment.address = header.p_paddr;
    segment.executable = header.p_flags & PF_X;
    segment.data.resize(header.p_memsz);

    std::copy_n(file.begin() + header.p_offset, header.p_filesz,
                segment.data.begin());

    return segment;
}

bool fits(const PagedMem& memory, const ElfSegment& segment) {
    uint64_t end = uint64_t(segment.address) + segment.data.size();
    uint64_t limit = uint64_t(std::numeric_limits<uint32_t>::max()) + 1;

    return end <= limit &&
           memory.in_range(segment.address) &&
           memory.in_range(uint32_t(end - 1));
}

}  // namespace

ElfImage read_elf(const char* path) {
    File file = read_file(path);
    Elf32_Ehdr header = read_at<Elf32_Ehdr>(file, 0);
    validate(header);

    ElfImage image = {header.e_machine, header.e_entry, {}};
    for (uint16_t i = 0; i < header.e_phnum; ++i) {
        size_t offset = header.e_phoff + size_t(i) * header.e_phentsize;
        Elf32_Phdr program = read_at<Elf32_Phdr>(file, offset);

        if (program.p_type == PT_LOAD && program.p_memsz != 0) {
            image.segments.push_back(read_segment(file, program));
        }
    }

    if (image.segments.empty()) {
        throw std::runtime_error("ELF has no loadable segments");
    }

    return image;
}

uint32_t load_elf(const char* path, PagedMem* memory) {
    ElfImage image = read_elf(path);

    for (const ElfSegment& segment : image.segments) {
        if (!fits(*memory, segment)) {
            throw std::runtime_error("ELF segment outside memory range");
        }

        for (size_t i = 0; i < segment.data.size(); ++i) {
            memory->write_byte(segment.address + uint32_t(i), segment.data[i]);
        }
    }

    return image.entry;
}

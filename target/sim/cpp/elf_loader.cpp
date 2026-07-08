#include <cstdint>
#include <cstring>
#include <fstream>
#include <vector>
#include <stdexcept>
#include "elf_loader.hpp"

struct Elf32_Ehdr {
    uint8_t  e_ident[16];
    uint16_t e_type, e_machine;
    uint32_t e_version, e_entry, e_phoff, e_shoff, e_flags;
    uint16_t e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx;
};

struct Elf32_Phdr {
    uint32_t p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align;
};

static constexpr uint32_t PT_LOAD = 1;

uint32_t load_elf(const char* path, PagedMem* mem) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open ELF");
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());

    Elf32_Ehdr eh;
    if (buf.size() < sizeof(eh)) throw std::runtime_error("truncated ELF");
    std::memcpy(&eh, buf.data(), sizeof(eh));

    if (std::memcmp(eh.e_ident, "\x7f" "ELF", 4) != 0)
        throw std::runtime_error("not an ELF");
    if (eh.e_ident[4] != 1) throw std::runtime_error("not ELF32");
    if (eh.e_ident[5] != 1) throw std::runtime_error("not little-endian");

    for (uint16_t i = 0; i < eh.e_phnum; i++) {
        Elf32_Phdr ph;
        std::memcpy(&ph, buf.data() + eh.e_phoff + i * eh.e_phentsize, sizeof(ph));
        if (ph.p_type != PT_LOAD) continue;

        if (ph.p_memsz != 0 &&
            (!mem->in_range(ph.p_paddr) || !mem->in_range(ph.p_paddr + ph.p_memsz - 1)))
            throw std::runtime_error("ELF segment outside memory range");

        for (uint32_t j = 0; j < ph.p_filesz; j++)
            mem->write_byte(ph.p_paddr + j, buf[ph.p_offset + j]);
        for (uint32_t j = ph.p_filesz; j < ph.p_memsz; j++)
            mem->write_byte(ph.p_paddr + j, 0);
    }
    return eh.e_entry;
}

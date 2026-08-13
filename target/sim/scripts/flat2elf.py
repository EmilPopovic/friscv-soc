#!/usr/bin/env python3
# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Matej Jurasić <matej.jurasic@cappig.dev>

"""Wrap a flat boot image in a minimal ELF32 so the testbench can load it.

    flat2elf.py <image> <out.elf> [load address]
"""

import struct
import sys

EHDR = 52
PHDR = 32
EM_RISCV = 243


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)

    src, dst = sys.argv[1], sys.argv[2]
    base = int(sys.argv[3], 0) if len(sys.argv) == 4 else 0x80000000
    payload = open(src, "rb").read()

    ehdr = (b"\x7fELF\x01\x01\x01" + bytes(9) +
            struct.pack("<HHIIIIIHHHHHH", 2, EM_RISCV, 1, base, EHDR, 0, 0,
                        EHDR, PHDR, 1, 0, 0, 0))
    phdr = struct.pack("<IIIIIIII", 1, EHDR + PHDR, base, base,
                       len(payload), len(payload), 7, 0x1000)

    open(dst, "wb").write(ehdr + phdr + payload)
    print(f"{dst}: {len(payload)} bytes at {base:#010x}")


if __name__ == "__main__":
    main()

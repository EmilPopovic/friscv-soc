#!/usr/bin/env python3
# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Matej Jurasić <matej.jurasic@cappig.dev>
# Emil Popović <mail@emilpopovic.me>

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CONFIGS = {
    "core": ("friscv-full", "elfs"),
    "soc": ("friscv-soc", "elfs-soc"),
}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in CONFIGS:
        print(f"usage: {sys.argv[0]} <core|soc>", file=sys.stderr)
        sys.exit(1)

    config, destination = CONFIGS[sys.argv[1]]
    src = ROOT / "riscv-arch-test" / "work" / config / "elfs"
    dst = ROOT / destination

    if not src.exists():
        print(f"ELF directory not found: {src}", file=sys.stderr)
        sys.exit(1)

    dst.mkdir(parents=True, exist_ok=True)
    for elf in src.rglob("*.elf"):
        shutil.copy2(elf, dst / elf.name)
    print(f"copied {len(list(dst.glob('*.elf')))} elfs into {dst}")

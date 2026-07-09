#!/usr/bin/env python3
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "riscv-arch-test" / "work" / "friscv-full" / "elfs"
DST = ROOT / "elfs"

if __name__ == "__main__":
    DST.mkdir(parents=True, exist_ok=True)
    for elf in SRC.rglob("*.elf"):
        shutil.copy2(elf, DST / elf.name)
    print(f"copied {len(list(DST.glob('*.elf')))} elfs into {DST}")

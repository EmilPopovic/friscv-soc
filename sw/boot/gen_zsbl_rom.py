#!/usr/bin/env python3
# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
"""Assemble the ZSBL and emit the package friscv_zsbl_rom.sv reads its words from."""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

CROSS = "riscv64-unknown-elf"
ROOT = Path(__file__).resolve().parents[2]
SOC = ROOT / "rtl/soc/friscv_soc.sv"

HEADER = """\
// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
"""


def find(text: str, pattern: str, what: str, where: Path) -> str:
    match = re.search(pattern, text)
    if not match:
        raise SystemExit(f"{where}: could not find {what}")

    return match.group(1)


def check_against_soc(source: Path):
    """The loader pokes the pinmux by address; the assembler cannot check that."""
    asm, soc = source.read_text(), SOC.read_text()

    want = [
        ("pad base",
         int(find(asm, r"\.equ\s+QSPI_PAD_BASE,\s*(\d+)", "QSPI_PAD_BASE", source)),
         int(find(soc, r"Qspi0PadBase\s*=\s*(\d+)", "Qspi0PadBase", SOC))),
        ("pinmux base",
         int(find(asm, r"\.equ\s+PINMUX_BASE,\s*(0x[0-9a-fA-F]+)", "PINMUX_BASE", source), 16),
         int(find(soc, r"idx:\s*PinmuxPort\s*,\s*start_addr:\s*32'h([0-9a-fA-F_]+)",
                  "the pinmux address map entry", SOC).replace("_", ""), 16)),
    ]

    for name, in_asm, in_soc in want:
        if in_asm != in_soc:
            raise SystemExit(
                f"{source.name} has {name} {in_asm:#x}, {SOC.name} says {in_soc:#x}")


def assemble(source: Path, work: Path) -> bytes:
    elf = work / "zsbl.elf"
    binary = work / "zsbl.bin"

    subprocess.run(
        [f"{CROSS}-gcc", "-march=rv32ima_zicsr_zifencei", "-mabi=ilp32",
         "-nostdlib", "-nostartfiles", "-Wl,--no-warn-rwx-segments",
         "-Wl,-Ttext=0", "-o", str(elf), str(source)],
        check=True,
    )
    subprocess.run([f"{CROSS}-objcopy", "-O", "binary", str(elf), str(binary)],
                   check=True)

    return binary.read_bytes()


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: gen_zsbl_rom.py <zsbl.S> <out.sv>")

    source, out = Path(sys.argv[1]), Path(sys.argv[2])

    check_against_soc(source)

    with tempfile.TemporaryDirectory() as tmp:
        image = assemble(source, Path(tmp))

    if len(image) % 4:
        image += bytes(4 - len(image) % 4)

    words = [int.from_bytes(image[i:i + 4], "little")
             for i in range(0, len(image), 4)]

    lines = [HEADER,
             f"// Generated from {source.name} by {Path(sys.argv[0]).name}, do not edit",
             f"package {out.stem};",
             "",
             "    import friscv_pkg::*;",
             "",
             f"    localparam int unsigned ZSBL_PROG_WORDS = {len(words)};",
             f"    localparam inst_t ZSBL_PROG [{len(words)}] = '{{"]
    lines += [f"        32'h{word:08x}{',' if i + 1 < len(words) else ''}"
              for i, word in enumerate(words)]
    lines += ["    };", "", f"endpackage : {out.stem}"]

    out.write_text("\n".join(lines) + "\n")
    print(f"{out}: {len(words)} words, {len(image)} bytes")


if __name__ == "__main__":
    main()

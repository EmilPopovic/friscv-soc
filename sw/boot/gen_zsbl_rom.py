#!/usr/bin/env python3
# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
"""Assemble the ZSBL and emit the package friscv_zsbl_rom.sv reads its words from.

    gen_zsbl_rom.py sw/boot/zsbl.S rtl/core/friscv_zsbl_rom_pkg.sv

Pass the chip that maps the qspi pads to check the numbers the loader hardcodes,
and --check to verify the committed package rather than rewrite it. The tapeout
repo does both in make check-rom.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

CROSS = "riscv64-unknown-elf"

HEADER = """\
// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
"""


def find(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text)

    return match.group(1) if match else None


def check_against_soc(source: Path, soc_path: Path):
    """The loader pokes the pinmux by address and the assembler cannot check
    that. The pad map lives in the chip that instantiates this soc."""
    asm, soc = source.read_text(), soc_path.read_text()

    want = [
        ("pad base",
         find(asm, r"\.equ\s+QSPI_PAD_BASE,\s*(\d+)"),
         find(soc, r"Qspi0PadBase\s*=\s*(\d+)"), 10),
        ("pinmux base",
         find(asm, r"\.equ\s+PINMUX_BASE,\s*(0x[0-9a-fA-F]+)"),
         find(soc, r"PinmuxBaseAddr\s*=\s*32'h([0-9a-fA-F_]+)")
         or find(soc, r"idx:\s*PinmuxPort\s*,\s*start_addr:\s*32'h([0-9a-fA-F_]+)"), 16),
    ]

    for name, in_asm, in_soc, base in want:
        if in_asm is None or in_soc is None:
            raise SystemExit(f"{name} is not declared in both files")

        if int(in_asm, base) != int(in_soc.replace("_", ""), base):
            raise SystemExit(
                f"{source.name} has {name} {in_asm}, {soc_path.name} says {in_soc}")


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
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv

    if len(args) not in (2, 3):
        raise SystemExit(
            "usage: gen_zsbl_rom.py <zsbl.S> <out.sv> [chip.sv] [--check]")

    source, out = Path(args[0]), Path(args[1])

    # The chip is optional, only it knows which pads the loader pokes
    if len(args) == 3:
        check_against_soc(source, Path(args[2]))

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

    text = "\n".join(lines) + "\n"

    # --check leaves the file alone and only reports whether it is current
    if check:
        if out.read_text() != text:
            raise SystemExit(f"{out} is stale, regenerate it")

        print(f"{out}: up to date, {len(words)} words, {len(image)} bytes")
        return

    out.write_text(text)
    print(f"{out}: {len(words)} words, {len(image)} bytes")


if __name__ == "__main__":
    main()

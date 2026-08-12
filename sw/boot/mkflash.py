#!/usr/bin/env python3
# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
"""Pack a boot image for the QSPI flash: second stage, header, payload."""

import sys
from pathlib import Path

BLOCK = 512
MAGIC = 0x43535246  # "FRSC", must match fsbl.S


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: mkflash.py <fsbl.bin> <payload> <out.bin>")

    fsbl, payload, out = (Path(a) for a in sys.argv[1:])
    stage = fsbl.read_bytes()

    if len(stage) > BLOCK:
        raise SystemExit(f"second stage is {len(stage)} bytes, over the {BLOCK} the ROM reads")

    image = payload.read_bytes()
    image += bytes(-len(image) % 4)

    checksum = sum(int.from_bytes(image[i:i + 4], "little")
                   for i in range(0, len(image), 4)) & 0xffffffff

    header = b"".join(v.to_bytes(4, "little") for v in (MAGIC, len(image), checksum))
    out.write_bytes(stage.ljust(BLOCK, b"\0") + header + image)
    print(f"{out}: {len(stage)} B stage + {len(image)} B payload")


if __name__ == "__main__":
    main()

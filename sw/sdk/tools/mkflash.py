#!/usr/bin/env python3
# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Matej Jurasić <matej.jurasic@cappig.dev>

# Pack a QSPI flash image

import sys
from pathlib import Path

STAGE_BYTES = 0x1000  # Matches STAGE_BYTES in zsbl.S
MAGIC = 0x43535246    # "FRSC", must match fsbl.S


def word(value):
    return value.to_bytes(4, "little")


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: mkflash.py <stage.bin> <payload> <out.bin>")

    stage_path, payload, out = (Path(a) for a in sys.argv[1:])

    stage = stage_path.read_bytes()

    if len(stage) > STAGE_BYTES:
        raise SystemExit(f"stage is {len(stage)} bytes, ROM reads {STAGE_BYTES}")

    image = payload.read_bytes()
    image += bytes(-len(image) % 4)

    checksum = sum(int.from_bytes(image[i:i + 4], "little")
                   for i in range(0, len(image), 4)) & 0xffffffff

    header = b"".join(word(v) for v in (MAGIC, len(image), checksum))
    out.write_bytes(stage.ljust(STAGE_BYTES, b"\0") + header + image)
    print(f"{out}: {len(stage)} B stage + {len(image)} B payload")


if __name__ == "__main__":
    main()

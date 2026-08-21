#!/usr/bin/env python3
# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Matej Jurasić <matej.jurasic@cappig.dev>

# Pack an SD card image

import sys
from pathlib import Path

BLOCK = 512
MAGIC = 0x43535246  # "FRSC", must match sdbl.c


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: mksdimg.py <payload> <out.img>")

    payload, out = (Path(a) for a in sys.argv[1:])

    image = payload.read_bytes()
    image += bytes(-len(image) % 4)

    checksum = sum(int.from_bytes(image[i:i + 4], "little")
                   for i in range(0, len(image), 4)) & 0xffffffff

    header = b"".join(v.to_bytes(4, "little") for v in (MAGIC, len(image), checksum))

    out.write_bytes(header.ljust(BLOCK, b"\0") + image + bytes(-len(image) % BLOCK))
    print(f"{out}: {len(image)} B payload in {1 + (len(image) + BLOCK - 1) // BLOCK} blocks")


if __name__ == "__main__":
    main()

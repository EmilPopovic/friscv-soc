#!/usr/bin/env python3
"""Pack a boot image for the QSPI flash: second stage, length, payload."""

import sys
from pathlib import Path

BLOCK = 512


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: mkflash.py <stage2.bin> <payload> <out.bin>")

    stage2, payload, out = (Path(a) for a in sys.argv[1:])
    stage = stage2.read_bytes()

    if len(stage) > BLOCK:
        raise SystemExit(f"second stage is {len(stage)} bytes, over the {BLOCK} the ROM reads")

    image = payload.read_bytes()
    image += bytes(-len(image) % 4)

    out.write_bytes(stage.ljust(BLOCK, b"\0") + len(image).to_bytes(4, "little") + image)
    print(f"{out}: {len(stage)} B stage + {len(image)} B payload")


if __name__ == "__main__":
    main()

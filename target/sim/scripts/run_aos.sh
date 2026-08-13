#!/usr/bin/env bash
# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Matej Jurasić <matej.jurasic@cappig.dev>
#
# Boot an apheleiaOS flat image on the SoC simulator and print its console.
# Build the image first, in an apheleiaOS checkout:
#
#   make all ARCH=riscv_32 TOOLCHAIN=llvm RISCV_FRISC=true
#
# then point this at bin/apheleia_*.img:
#
#   scripts/run_aos.sh ../aos/bin/apheleia_1.0_riscv_32.img
#
# The image loads at MEM_BASE and runs from the cached external memory, so the
# whole SRAM is free to be cache. Its kernel sits 32 MB in and its scratch area
# 48 MB in, which is why the memory is sized well past the 16 MB default.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

[ $# -eq 1 ] || { echo "usage: run_aos.sh <apheleia.img>" >&2; exit 1; }
[ -f "$1" ] || { echo "no such image: $1" >&2; exit 1; }

# Resolve before leaving the caller's directory
IMAGE=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
cd "$HERE/.."

MEM_SIZE=${MEM_SIZE:-268435456}
LLCSEL=${LLCSEL:-0xf}
UART_DIV=${UART_DIV:-27}          # 115200 baud from a 50 MHz clock
CYCLES=${CYCLES:-20000000000}
DIR=obj_dir_aos

mkdir -p "$DIR"
make soc SOC_MEM_SIZE="$MEM_SIZE" SOC_DIR="$DIR" >/dev/null

# boot through the ROM and the flash instead of the debug module
if [ "${BOOT:-jtag}" = qspi ]; then
    BOOT_SRC=$HERE/../../../sw/boot

    riscv64-unknown-elf-gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 \
        -nostdlib -nostartfiles -Wl,--no-warn-rwx-segments -Wl,-Ttext=0 \
        -o "$DIR/fsbl.elf" "$BOOT_SRC/fsbl.S"
    riscv64-unknown-elf-objcopy -O binary "$DIR/fsbl.elf" "$DIR/fsbl.bin"
    python3 "$BOOT_SRC/mkflash.py" "$DIR/fsbl.bin" "$IMAGE" "$DIR/flash.bin"

    # The fsbl sets the divisor and the cache ways itself
    exec env VERNII_UART_DIV="$UART_DIV" VERNII_TEST_CYCLES="$CYCLES" \
        "./$DIR/vernii_soc" qspiboot "$DIR/flash.bin"
fi

python3 "$HERE/flat2elf.py" "$IMAGE" "$DIR/aos.elf"

# The boot stub expects the baud rate to be set already, as a real boot ROM
# would, and never programs the divisor itself
VERNII_LLCSEL="$LLCSEL" \
VERNII_UART_DIV="$UART_DIV" \
VERNII_TEST_CYCLES="$CYCLES" \
    "./$DIR/vernii_soc" test "$DIR/aos.elf"

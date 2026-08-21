#!/usr/bin/env bash
# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Matej Jurasić <matej.jurasic@cappig.dev>

# Boot an apheleiaOS image on the simulator

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

# Boot from the SD card
if [ "${BOOT:-jtag}" = sd ]; then
    BOOT_SRC=$HERE/../../../sw/boot

    riscv64-unknown-elf-gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 -Os \
        -Wall -Wextra -nostdlib -nostartfiles -Wl,--no-warn-rwx-segments \
        -T "$BOOT_SRC/stage.ld" -o "$DIR/sdbl.elf" "$BOOT_SRC/sdbl.c"
    riscv64-unknown-elf-objcopy -O binary "$DIR/sdbl.elf" "$DIR/sdbl.bin"

    # The flash only carries the stage
    python3 "$BOOT_SRC/mkflash.py" "$DIR/sdbl.bin" /dev/null "$DIR/flash.bin"
    python3 "$BOOT_SRC/mksdimg.py" "$IMAGE" "$DIR/sd.img"

    exec env VERNII_UART_DIV="$UART_DIV" VERNII_TEST_CYCLES="$CYCLES" \
        VERNII_SD_IMAGE="$DIR/sd.img" \
        "./$DIR/vernii_soc" qspiboot "$DIR/flash.bin"
fi

# Boot from the flash
if [ "${BOOT:-jtag}" = qspi ]; then
    BOOT_SRC=$HERE/../../../sw/boot

    riscv64-unknown-elf-gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 \
        -nostdlib -nostartfiles -Wl,--no-warn-rwx-segments -Wl,-Ttext=4 \
        -o "$DIR/fsbl.elf" "$BOOT_SRC/fsbl.S"
    riscv64-unknown-elf-objcopy -O binary "$DIR/fsbl.elf" "$DIR/fsbl.bin"
    python3 "$BOOT_SRC/mkflash.py" "$DIR/fsbl.bin" "$IMAGE" "$DIR/flash.bin"

    # The fsbl sets the divisor itself
    exec env VERNII_UART_DIV="$UART_DIV" VERNII_TEST_CYCLES="$CYCLES" \
        "./$DIR/vernii_soc" qspiboot "$DIR/flash.bin"
fi

python3 "$HERE/flat2elf.py" "$IMAGE" "$DIR/aos.elf"

# The image expects the baud rate set
VERNII_LLCSEL="$LLCSEL" \
VERNII_UART_DIV="$UART_DIV" \
VERNII_TEST_CYCLES="$CYCLES" \
    "./$DIR/vernii_soc" test "$DIR/aos.elf"

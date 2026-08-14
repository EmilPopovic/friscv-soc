#!/usr/bin/env bash
# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Matej Jurasić <matej.jurasic@cappig.dev>
#
# Fetch, build and boot apheleiaOS. Needs clang, ld.lld and dtc.
#
#   aos.sh           boot, building only if there is no image yet
#   aos.sh rebuild   build again first

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE/.."

AOS_DIR=${AOS_DIR:-build_aos}
AOS_REPO=${AOS_REPO:-https://github.com/cappig/apheleiaOS.git}
SRC=$AOS_DIR/apheleiaOS

find_image() {
    ls "$SRC"/bin/apheleia_*_riscv_32.img 2>/dev/null | head -1
}

if [ "${1:-}" = rebuild ]; then
    rm -f "$SRC"/bin/apheleia_*_riscv_32.img
fi

image=$(find_image || true)

if [ -z "$image" ]; then
    for tool in clang ld.lld dtc; do
        command -v "$tool" >/dev/null ||
            { echo "$tool is required to build apheleiaOS" >&2; exit 1; }
    done

    [ -d "$SRC/.git" ] || git clone --depth 1 "$AOS_REPO" "$SRC"

    # RISCV_FRISC selects the FRISC device tree and the register stride this
    # SoC's 16550 uses, and drops the M extension the build notes call unstable
    make -C "$SRC" all ARCH=riscv_32 TOOLCHAIN=llvm RISCV_FRISC=true

    image=$(find_image)
    [ -n "$image" ] || { echo "build produced no image" >&2; exit 1; }
fi

echo "booting $image"
exec "$HERE/run_aos.sh" "$image"

/* Copyright 2026 FER, HPC Architecture and Application Research Center
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * The boot ROM drops a stage at zero and jumps there, so _start has to be the
 * first byte. Leaving that to orphan section placement puts whatever the
 * compiler emitted first at the entry point instead.
 *
 * Matej Jurasić <matej.jurasic@cappig.dev>
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0;
  .text.init : { *(.text.init) }
  .text      : { *(.text .text.*) }
  .rodata    : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data      : { *(.data .data.* .sdata .sdata.*) }
  .bss       : { *(.bss .bss.* .sbss .sbss.* COMMON) }
  _end = .;
}

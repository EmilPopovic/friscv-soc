/* Copyright 2026 FER, HPC Architecture and Application Research Center
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Directed tests link into external memory so they run through the LLC
 *
 * Emil Popović <mail@emilpopovic.me>
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text     : { *(.text .text.*) }
  .rodata   : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data     : { *(.data .data.* .sdata .sdata.*) }
  .bss      : { *(.bss .bss.* .sbss .sbss.* COMMON) }
  _end = .;

  /* C tests need a stack, the assembly ones never touch sp */
  . = ALIGN(16);
  . += 0x4000;
  _stack_top = .;
}

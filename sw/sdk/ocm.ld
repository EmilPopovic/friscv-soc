/* Copyright 2026 FER, HPC Architecture and Application Research Center
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Matej Jurasić <matej.jurasic@cappig.dev>
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

STACK_SIZE = DEFINED(STACK_SIZE) ? STACK_SIZE : 1K;

MEMORY
{
  ocm (rwx) : ORIGIN = 0x00000000, LENGTH = 8K
}

SECTIONS
{
  .text : { *(.text.init) *(.text .text.*) } > ocm
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > ocm

  . = ALIGN(4);
  __global_pointer$ = . + 0x800;
  .data : { *(.data .data.* .sdata .sdata.*) } > ocm

  .bss ALIGN(4) :
  {
    _bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > ocm

  _stack_top = ORIGIN(ocm) + LENGTH(ocm);
  ASSERT(_bss_end + STACK_SIZE <= _stack_top, "program leaves no room for the stack")
}

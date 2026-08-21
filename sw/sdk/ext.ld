/* Copyright 2026 FER, HPC Architecture and Application Research Center
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Matej Jurasić <matej.jurasic@cappig.dev>
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

STACK_SIZE = DEFINED(STACK_SIZE) ? STACK_SIZE : 16K;

MEMORY
{
  ext (rwx) : ORIGIN = 0x80000000, LENGTH = DEFINED(EXT_SIZE) ? EXT_SIZE : 16M
}

SECTIONS
{
  .text : { *(.text.init) *(.text .text.*) } > ext
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > ext

  . = ALIGN(4);
  __global_pointer$ = . + 0x800;
  .data : { *(.data .data.* .sdata .sdata.*) } > ext

  .bss ALIGN(4) :
  {
    _bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > ext

  _stack_top = _bss_end + STACK_SIZE;
  . = _stack_top;
}

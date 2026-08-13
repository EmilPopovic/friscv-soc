/* Copyright 2026 FER, HPC Architecture and Application Research Center
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Emil Popović <mail@emilpopovic.me>
 */

OUTPUT_ARCH( "riscv" )
ENTRY( _start )

SECTIONS
{
  . = 0x200000;

  .text : {
    *(.text)
  }

  .data : { *(.data) }
  .bss : { *(.bss) }
}

// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
//
// First stage for the UART boot test. Links at zero, where the boot ROM leaves
// it. The testbench fills the block from PATTERN on with a known sequence, so
// checking it catches a transfer that only got the opening instructions right.

.equ SCRATCH, 0x03000000        # SCB.SCRATCH0, where the testbench reads the result
.equ HALT,    0x50000000        # END_ADDRESS to end simulation
.equ PASS,    0xaabbccdd
.equ FAIL,    0xdeadbeef

.equ PATTERN, 256               # must match STAGE_PATTERN_START in tb_soc_main
.equ BLOCK,   512

.section .text.init
.global _start
_start:
    li   t0, PATTERN
    li   t3, BLOCK

1:  lbu  t1, 0(t0)
    slli t2, t0, 3
    sub  t2, t2, t0             # offset * 7
    addi t2, t2, 0x5a
    andi t2, t2, 0xff
    bne  t1, t2, fail
    addi t0, t0, 1
    blt  t0, t3, 1b

pass:
    li   t0, SCRATCH
    li   t1, PASS
    sw   t1, 0(t0)
    li   t0, HALT
    sw   zero, 0(t0)
2:  j    2b

fail:
    li   t0, SCRATCH
    li   t1, FAIL
    sw   t1, 0(t0)
    li   t0, HALT
    sw   zero, 0(t0)
3:  j    3b

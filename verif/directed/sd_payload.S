// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
//
// Payload for the SD boot test. sdbl.c copies it off the card to RAM_BASE and
// jumps here, so reaching it at all means the card was read and checksummed.

.equ SCRATCH, 0x03000000
.equ HALT,    0x50000000
.equ PASS,    0xaabbccdd

.section .text.init
.global _start
_start:
    li   t0, SCRATCH
    li   t1, PASS
    sw   t1, 0(t0)
    li   t0, HALT
    sw   zero, 0(t0)
1:  j    1b

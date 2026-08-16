// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>

.equ SCRATCH, 0x03000000        # SCB.SCRATCH0, where the testbench reads the result
.equ HALT,    0x50000000        # END_ADDRESS to end simulation
.equ PASS,    0xaabbccdd
.equ FAIL,    0xdeadbeef

.equ REGION,  0x80040000        # 256 KiB into external memory, clear of this code
.equ SETOFF,  224               # set 7
.equ TAGSTR,  2048              # Sets * LineBytes: same set, next tag
.equ NTAG,    32                # 32 tags competing for 4 ways
.equ SWEEP,   0x8000            # 32 KiB, larger than the cache

.section .text.init
.global _start
_start:

# Test 1: thrash one set with NTAG tags
    li   s0, REGION
    addi s0, s0, SETOFF
    li   s3, TAGSTR
    li   s4, NTAG

    mv   t0, s0                 # fill
    li   s1, 0
1:  xori t2, t0, 0x5a5
    sw   t2, 0(t0)
    add  t0, t0, s3
    addi s1, s1, 1
    blt  s1, s4, 1b

    li   s5, 0                  # verify twice: first pass misses, second hits
4:  mv   t0, s0
    li   s1, 0
2:  xori t2, t0, 0x5a5
    lw   t3, 0(t0)
    bne  t2, t3, fail
    add  t0, t0, s3
    addi s1, s1, 1
    blt  s1, s4, 2b
    addi s5, s5, 1
    li   t4, 2
    blt  s5, t4, 4b

# Test 2: sweep 32 KiB across every set and many tags
    li   s0, REGION
    li   s6, SWEEP
    add  s7, s0, s6

    mv   t0, s0                 # fill, write-through
5:  xori t2, t0, 0x5a5
    sw   t2, 0(t0)
    addi t0, t0, 4
    bltu t0, s7, 5b

    mv   t0, s0                 # verify, mostly misses and refills
6:  xori t2, t0, 0x5a5
    lw   t3, 0(t0)
    bne  t2, t3, fail
    addi t0, t0, 4
    bltu t0, s7, 6b

    mv   t0, s0                 # verify again, mix of hits and evictions
7:  xori t2, t0, 0x5a5
    lw   t3, 0(t0)
    bne  t2, t3, fail
    addi t0, t0, 4
    bltu t0, s7, 7b

pass:
    li   t0, SCRATCH
    li   t1, PASS
    sw   t1, 0(t0)
    li   t0, HALT
    sw   zero, 0(t0)
9:  j    9b

fail:
    li   t0, SCRATCH
    li   t1, FAIL
    sw   t1, 0(t0)
    li   t0, HALT
    sw   zero, 0(t0)
8:  j    8b

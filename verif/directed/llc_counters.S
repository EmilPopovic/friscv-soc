// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>

# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

.equ SCB,       0x03000000
.equ SCRATCH0,  0x000
.equ LLCSEL,    0x00C
.equ LLCRDACC,  0x018
.equ LLCRDMISS, 0x020
.equ LLCWRACC,  0x028

.equ HALT,  0x50000000
.equ PASS,  0xaabbccdd
.equ FAIL,  0xdeadbeef

.equ DATA,  0x80100000
.equ NWORD, 64                  # 64 words = 8 lines at 32 B per line
.equ NLINE, 8

.section .text.init
.global _start
_start:
    li   s0, SCB
    li   s1, DATA
    li   s2, NWORD

    # Warm the loop's own cache lines so the measured passes see warm code
    jal  ra, read_pass
    jal  ra, read_pass

# LLCWRACC must equal the number of stores exactly
    sw   zero, LLCWRACC(s0)
    jal  ra, write_pass
    lw   t2, LLCWRACC(s0)
    bne  t2, s2, fail

# a cold read pass must miss once per line
    # invalidate so the data is cold regardless of what ran before
    li   t0, 1
    sw   t0, 0x014(s0)          # LLCINV
    sw   zero, LLCRDACC(s0)
    sw   zero, LLCRDMISS(s0)
    jal  ra, read_pass
    lw   s3, LLCRDACC(s0)       # cold accesses
    lw   s4, LLCRDMISS(s0)      # cold misses

    blt  s3, s2, fail
    li   t0, NLINE
    blt  s4, t0, fail

# a warm pass over the same data must miss less
    sw   zero, LLCRDACC(s0)
    sw   zero, LLCRDMISS(s0)
    jal  ra, read_pass
    lw   s5, LLCRDACC(s0)       # warm accesses
    lw   s6, LLCRDMISS(s0)      # warm misses

    # same instructions and data so the access count must match
    bne  s5, s3, fail
    # and the warm pass must miss less than the cold one
    bge  s6, s4, fail

# clearing must actually clear
    sw   zero, LLCRDMISS(s0)
    lw   t2, LLCRDMISS(s0)
    li   t0, 4
    bgt  t2, t0, fail

pass:
    li   t0, SCB
    li   t1, PASS
    sw   t1, SCRATCH0(t0)
    li   t0, HALT
    sw   zero, 0(t0)
9:  j    9b

fail:
    li   t0, SCB
    li   t1, FAIL
    sw   t1, SCRATCH0(t0)
    li   t0, HALT
    sw   zero, 0(t0)
8:  j    8b

# NWORD stores over the data region
write_pass:
    mv   t0, s1
    li   t1, 0
1:  sw   t1, 0(t0)
    addi t0, t0, 4
    addi t1, t1, 1
    blt  t1, s2, 1b
    ret

# NWORD loads over the data region
read_pass:
    mv   t0, s1
    li   t1, 0
1:  lw   t3, 0(t0)
    addi t0, t0, 4
    addi t1, t1, 1
    blt  t1, s2, 1b
    ret

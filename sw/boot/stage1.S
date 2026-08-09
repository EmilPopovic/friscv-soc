// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// First stage, loaded into the OCM by the boot rom. Brings up external memory,
// streams the image into RAM and enters it. A bad header parks for the DM.
//
// Flash: this stage in the first block, then magic, length, checksum, image.

#define SCB_SCRATCH 0x40000000
#define SCB_HBCTL   0x40000008
#define SCB_LLCSEL  0x4000000C
#define UART0       0x10000000
#define UART_DLL    0x00
#define UART_DLM    0x04
#define UART_LCR    0x0c
#define F_CPU       50000000
#define BAUD        115200
#define MTIME_HZ    10000000        // must match timebase-frequency in the dtb
#define UART_DIV    ((F_CPU + 8 * BAUD) / (16 * BAUD))
#define ACLINT_TICK 0x0200c000      // TICKTARGET, TICKSOURCE follows
#define SPI_STATUS  0x14
#define SPI_COMMAND 0x28
#define SPI_RXDATA  0x2c
#define SPI_TXDATA  0x30
#define RAM_BASE    0x80000000
#define MAGIC       0x43535246      // "FRSC", little endian
#define MAX_IMAGE   0x10000000      // largest memory this SoC is built with
#define BAD_HEADER  0xbad00001      // odd, never a real entry point
#define BAD_CKSUM   0xbad00003
#define BLOCK       512
#define RX_CSAAT    0x13ff          // csaat | RX | 512 bytes

    .section .text.init
    .globl _start
_start:
    // Ways stay scratchpad, this code runs from the OCM
    li      t0, SCB_HBCTL
    li      t1, 1
    sw      t1, 0(t0)

    // mtime runs at MTIME_HZ whatever the core clock is, the aclint comes out
    // of reset at 1:1
    lui     t0, %hi(ACLINT_TICK)
    li      t1, MTIME_HZ
    sw      t1, 0(t0)
    li      t1, F_CPU
    sw      t1, 4(t0)

    // the apheleiaOS stub expects the divisor set
    li      t0, UART0
    li      t1, 0x80
    sw      t1, UART_LCR(t0)
    li      t1, UART_DIV
    sw      t1, UART_DLL(t0)
    sw      zero, UART_DLM(t0)
    li      t1, 0x03
    sw      t1, UART_LCR(t0)

    lui     t0, 0x60000

    // fresh read, the ROM released CS: 03 00 02 00 LSB first, address 0x200
    li      t1, 0x00020003
    sw      t1, SPI_TXDATA(t0)
    li      t1, 0x2203              // csaat | TX | 4 bytes
    sw      t1, SPI_COMMAND(t0)

    li      t1, RX_CSAAT
    sw      t1, SPI_COMMAND(t0)

    // Header: magic, length, checksum
    jal     rx_word
    li      t1, MAGIC
    bne     a0, t1, bad_header
    jal     rx_word
    mv      s0, a0                  // bytes still to move
    beqz    s0, bad_header
    li      t1, MAX_IMAGE
    bgeu    s0, t1, bad_header      // unsigned, catches 0xffffffff
    jal     rx_word
    mv      s2, a0                  // expected checksum

    li      s3, 0
    li      s1, (BLOCK - 12) / 4    // words left in this block
    li      a1, RAM_BASE

copy:
    beqz    s1, next_block
1:  jal     rx_word
    sw      a0, 0(a1)
    add     s3, s3, a0
    addi    a1, a1, 4
    addi    s0, s0, -4
    addi    s1, s1, -1
    blez    s0, done
    bnez    s1, 1b

next_block:
    li      t1, RX_CSAAT
    sw      t1, SPI_COMMAND(t0)
    li      s1, BLOCK/4
    j       copy

    // the cache cannot be enabled from the OCM, finish from RAM
done:
    bne     s3, s2, bad_cksum
    mv      s0, a1                  // just past the image
    la      a1, tramp
    la      a2, tramp_end
    mv      a3, s0
1:  lw      t1, 0(a1)
    sw      t1, 0(a3)
    addi    a1, a1, 4
    addi    a3, a3, 4
    bltu    a1, a2, 1b
    fence.i
    jr      s0

bad_header:
    li      a0, BAD_HEADER
    j       park
bad_cksum:
    li      a0, BAD_CKSUM

// leave the code in scratch, wait for an entry point
park:
    li      t0, SCB_SCRATCH
    sw      a0, 0(t0)
1:  lw      t1, 0(t0)
    beq     t1, a0, 1b
    fence.i
    jr      t1

tramp:
    li      t0, SCB_LLCSEL
    li      t1, 0xf                 // every way a cache way
    sw      t1, 0(t0)
    li      t0, RAM_BASE
    jr      t0
tramp_end:

// One word out of the rx fifo
rx_word:
1:  lw      a0, SPI_STATUS(t0)
    slli    a0, a0, 7               // rxempty is bit 24
    bltz    a0, 1b
    lw      a0, SPI_RXDATA(t0)
    ret

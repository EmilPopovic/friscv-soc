// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
// Emil Popović <mail@emilpopovic.me>
//
// Zero stage boot loader. PA0 low parks for the debug module, high loads a
// first stage from QSPI flash and runs it from zero.

.section .text
.global _start

.option arch, +zicsr

.equ SCB_BASE,     0x03000000
.equ SCB_SCRATCH0, 0x00
.equ SCB_STRAPA,   0x04

# gen_zsbl_rom.py checks these against vernii_soc.sv
.equ QSPI_BASE,    0x03020000
.equ SPI_CONTROL,  0x10
.equ SPI_CONFIGOPTS, 0x18
.equ SPI_STATUS,   0x14
.equ SPI_COMMAND,  0x28
.equ SPI_RXDATA,   0x2c
.equ SPI_TXDATA,   0x30
.equ FSBL_BYTES,  512           # one RX command's worth

_start:
    lui t0, (SCB_BASE >> 12)
    lw t1, SCB_STRAPA(t0)        # pads sampled at reset
    andi t1, t1, 1
    bnez t1, qspi

park:
    li t1, 1             # misaligned, never a real entry point
    sw t1, SCB_SCRATCH0(t0)
1:  lw t2, SCB_SCRATCH0(t0)
    beq t2, t1, 1b
    fence.i              # the DM wrote code
    jr t2

qspi:
    # The QSPI pads are dedicated, there is nothing to mux
    lui t0, (QSPI_BASE >> 12)
    sw t1, SPI_CONFIGOPTS(t0)    # CLKDIV=1: SCK = core clock / 4
    lui t1, 0xa0000              # SPIEN | OUTPUT_EN
    sw t1, SPI_CONTROL(t0)
    li t1, 3                     # 0x03 read from address 0, LSB first
    sw t1, SPI_TXDATA(t0)
    li t1, 0x2203                # csaat | TX | 4 bytes
    sw t1, SPI_COMMAND(t0)
    li t1, 0x11ff                # RX | 512 bytes, releases CS
    sw t1, SPI_COMMAND(t0)
    li a0, -FSBL_BYTES          # counts up to zero
2:  lw t2, SPI_STATUS(t0)
    slli t2, t2, 7               # rxempty is bit 24
    bltz t2, 2b
    lw t2, SPI_RXDATA(t0)
    sw t2, FSBL_BYTES(a0)
    addi a0, a0, 4
    bnez a0, 2b
    fence.i
    jr zero

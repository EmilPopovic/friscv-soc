// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
// Emil Popović <mail@emilpopovic.me>

// Zero stage boot loader

.section .text
.global _start

.option arch, +zicsr

.equ SCB_BASE,     0x03000000
.equ SCB_SCRATCH0, 0x00
.equ SCB_BOOTSEL,  0x04

# gen_zsbl_rom.py checks these against vernii_soc.sv
.equ QSPI_BASE,    0x03020000
.equ UART_BASE,    0x03010000
.equ SPI_CONTROL,  0x10
.equ SPI_CONFIGOPTS, 0x18
.equ SPI_STATUS,   0x14
.equ SPI_COMMAND,  0x28
.equ SPI_RXDATA,   0x2c
.equ SPI_TXDATA,   0x30
.equ UART_RBR,     0x00
.equ UART_DLL,     0x00
.equ UART_LCR,     0x0c
.equ UART_LSR,     0x14
.equ UART_THR,     0x00
.equ F_CPU,        50000000
.equ BAUD,         115200
.equ UART_DIV,     ((F_CPU + 8 * BAUD) / (16 * BAUD))
.equ SEG_BYTES,    512          # the most one RX command can carry
.equ STAGE_BYTES,  0x1000       # every stage is this long
.equ BANNER,       0x56          # 'V', sent before the first byte

_start:
    lui t0, (SCB_BASE >> 12)
    la t1, park
    csrw mtvec, t1               # nothing handles a trap, so park
    lw t1, SCB_BOOTSEL(t0)       # boot select pads
    li a0, 0                     # both loaders fill from zero
    li a2, STAGE_BYTES
    andi t2, t1, 2
    bnez t2, uart
    andi t1, t1, 1               # t1 = 1, the CLKDIV qspi writes
    bnez t1, qspi

# Also the trap handler, assumes nothing
park:
    lui t0, (SCB_BASE >> 12)
    li t1, 1                     # misaligned, never a real entry point
    sw t1, SCB_SCRATCH0(t0)
1:  lw t2, SCB_SCRATCH0(t0)
    beq t2, t1, 1b
    fence.i                      # the DM wrote code
    jr t2

uart:
    # DLM resets to zero, only DLL needed
    lui t0, (UART_BASE >> 12)
    li t1, 0x80
    sw t1, UART_LCR(t0)          # DLAB
    li t1, UART_DIV
    sw t1, UART_DLL(t0)
    li t1, 3
    sw t1, UART_LCR(t0)          # 8N1, DLAB off
    li t1, BANNER                # THR is empty out of reset
    sw t1, UART_THR(t0)
3:  lw t2, UART_LSR(t0)
    andi t2, t2, 1               # data ready
    beqz t2, 3b
    lw t2, UART_RBR(t0)
    sb t2, 0(a0)
    addi a0, a0, 1
    bltu a0, a2, 3b
    j done

qspi:
    # The QSPI pads are dedicated, there is nothing to mux
    lui t0, (QSPI_BASE >> 12)
    sw t1, SPI_CONFIGOPTS(t0)    # CLKDIV=1: SCK = core clock / 4
    lui t1, 0xa0000              # SPIEN | OUTPUT_EN
    sw t1, SPI_CONTROL(t0)
4:  slli a3, a0, 8               # 0x03 read from a0, address byte swapped
    addi a3, a3, 3
    sw a3, SPI_TXDATA(t0)
    li t1, 0x2203                # csaat | TX | 4 bytes
    sw t1, SPI_COMMAND(t0)
    li t1, 0x11ff                # RX | 512 bytes, releases CS
    sw t1, SPI_COMMAND(t0)
2:  lw t2, SPI_STATUS(t0)
    slli t2, t2, 7               # rxempty is bit 24
    bltz t2, 2b
    lw t2, SPI_RXDATA(t0)
    sw t2, 0(a0)
    addi a0, a0, 4
    andi t3, a0, (SEG_BYTES - 1)
    bnez t3, 2b                  # same segment
    bltu a0, a2, 4b              # next segment

done:
    fence.i
    jr zero

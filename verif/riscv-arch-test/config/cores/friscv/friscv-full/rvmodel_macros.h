// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define FRISCV_GPIO_ADDR  0x40000000
#define FRISCV_HALT_ADDR  0x50000000
#define FRISCV_PASS_VALUE 0xAABBCCDD
#define FRISCV_FAIL_VALUE 0x0BADC0DE

#define FRISCV_UART_BASE  0x10000000
#define FRISCV_UART_THR   (FRISCV_UART_BASE + 0x00)
#define FRISCV_UART_LCR   (FRISCV_UART_BASE + 0x0c)
#define FRISCV_UART_LSR   (FRISCV_UART_BASE + 0x14)

#define RVMODEL_DATA_SECTION

#define RVMODEL_BOOT

#define RVMODEL_HALT_PASS     \
    li t0, FRISCV_GPIO_ADDR;  \
    li t1, FRISCV_PASS_VALUE; \
    sw t1, 0(t0);             \
    li t0, FRISCV_HALT_ADDR;  \
    sw zero, 0(t0);           \
1:  j 1b;

#define RVMODEL_HALT_FAIL     \
    li t0, FRISCV_GPIO_ADDR;  \
    li t1, FRISCV_FAIL_VALUE; \
    sw t1, 0(t0);             \
    li t0, FRISCV_HALT_ADDR;  \
    sw zero, 0(t0);           \
1:  j 1b;

#define RVMODEL_IO_INIT(_R1, _R2, _R3) \
    li _R1, FRISCV_UART_LCR;           \
    li _R2, 3;                         \
    sb _R2, 0(_R1);

#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR) \
1:                                                    \
    lbu _R1, 0(_STR_PTR);                             \
    beqz _R1, 3f;                                     \
    li _R2, FRISCV_UART_LSR;                          \
2:                                                    \
    lbu _R3, 0(_R2);                                  \
    andi _R3, _R3, 0x20;                              \
    beqz _R3, 2b;                                     \
    li _R2, FRISCV_UART_THR;                          \
    sb _R1, 0(_R2);                                   \
    addi _STR_PTR, _STR_PTR, 1;                       \
    j 1b;                                             \
3:

#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000

#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_TIMER_INT_SOON_DELAY 100
#define RVMODEL_MTIME_ADDRESS    0x0200BFF8
#define RVMODEL_MTIMECMP_ADDRESS 0x02004000

#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)

#define RVMODEL_SET_MSW_INT(_R1, _R2) \
    li _R1, 1;                        \
    li _R2, 0x02000000;               \
    sw _R1, 0(_R2);

#define RVMODEL_CLR_MSW_INT(_R1, _R2) \
    li _R2, 0x02000000;               \
    sw zero, 0(_R2);

#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)

#define RVMODEL_SET_SSW_INT(_R1, _R2) \
    li _R1, 0x2;                      \
    csrs sip, _R1;

#define RVMODEL_CLR_SSW_INT(_R1, _R2) \
    li _R1, 0x2;                      \
    csrc sip, _R1;

#endif

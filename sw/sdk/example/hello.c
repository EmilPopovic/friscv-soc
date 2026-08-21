// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

#include "vernii.h"

#define F_CPU    50000000u
#define BAUD     115200u
#define UART_DIV ((F_CPU + 8 * BAUD) / (16 * BAUD))

static void uart_init(void) {
    WRITE_REG(UART0->LCR, 0x80);
    WRITE_REG(UART0->DLL, UART_DIV & 0xff);
    WRITE_REG(UART0->DLM, UART_DIV >> 8);
    WRITE_REG(UART0->LCR, 0x03);
}

static void uart_putc(char c) {
    while (!(READ_REG(UART0->LSR) & (1u << 5))) {
    }

    WRITE_REG(UART0->THR, (uint32_t)c);
}

static void uart_puts(const char* s) {
    for (; *s; s++) {
        uart_putc(*s);
    }
}

int main(void) {
    uart_init();
    uart_puts("hello from vernii\n");

    for (;;) {
    }
}

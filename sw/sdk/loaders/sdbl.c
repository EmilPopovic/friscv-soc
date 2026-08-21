// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

// Boots an image off the SD card

#include <stddef.h>
#include <stdint.h>

#include "vernii.h"

#define RAM_BASE  EXT_BASE
#define MAGIC     0x43535246u   // "FRSC", matches mkflash.py and fsbl.S
#define MAX_IMAGE 0x10000000u
// Top of the default OCM
#define STACK_TOP 0x00002000u

#ifndef F_CPU
#define F_CPU 50000000u
#endif
#ifndef BAUD
#define BAUD 115200u
#endif

#define UART_DIV  ((F_CPU + 8 * BAUD) / (16 * BAUD))
#define MTIME_HZ  10000000u

#define LCR_DLAB 0x80u
#define LCR_8N1  0x03u

#define CS_CARD  1u
#define CS_SPARE 2u

// SCK = core clock / (2 * (clkdiv + 1))
#define CLKDIV_SLOW 63u
#define CLKDIV_FAST 1u

#ifndef LLC_WAYS
#define LLC_WAYS 0xf
#endif

#define BLOCK_BYTES 512u
#define BLOCK_WORDS (BLOCK_BYTES / 4)
#define SPIN_LIMIT  2000000u

// Odd, so never a real entry point
#define BAD_CARD   0xbad00011u
#define BAD_HEADER 0xbad00013u
#define BAD_CKSUM  0xbad00015u

static int spi_command(unsigned bytes, unsigned csaat, uint32_t direction) {
    uint32_t word = ((bytes - 1) << QSPI_COMMAND_LEN_OFF) & QSPI_COMMAND_LEN_BM;

    if (csaat) {
        word |= QSPI_COMMAND_CSAAT_BM;
    }

    for (uint32_t i = 0; i < SPIN_LIMIT; i++) {
        if (READ_REG(QSPI0->STATUS) & QSPI_STATUS_READY_BM) {
            WRITE_REG(QSPI0->COMMAND, word | direction);
            return 1;
        }
    }

    return 0;
}

// CSID only changes between transactions
static void spi_wait_idle(void) {
    for (uint32_t i = 0; i < SPIN_LIMIT; i++) {
        if (!(READ_REG(QSPI0->STATUS) & QSPI_STATUS_ACTIVE_BM)
            && (READ_REG(QSPI0->STATUS) & QSPI_STATUS_READY_BM)) {
            return;
        }
    }
}

static int spi_put_word(uint32_t value) {
    for (uint32_t i = 0; i < SPIN_LIMIT; i++) {
        if (!(READ_REG(QSPI0->STATUS) & QSPI_STATUS_TXFULL_BM)) {
            WRITE_REG(QSPI0->TXDATA, value);
            return 1;
        }
    }

    return 0;
}

static int spi_get_word(uint32_t* out) {
    for (uint32_t i = 0; i < SPIN_LIMIT; i++) {
        if (!(READ_REG(QSPI0->STATUS) & QSPI_STATUS_RXEMPTY_BM)) {
            *out = READ_REG(QSPI0->RXDATA);
            return 1;
        }
    }

    return 0;
}

// First byte in is the least significant
static int spi_read_byte(uint8_t* out, unsigned csaat) {
    uint32_t word;

    if (!spi_command(1, csaat, QSPI_COMMAND_DIRECTION_RX) || !spi_get_word(&word)) {
        return 0;
    }

    *out = (uint8_t)(word & 0xff);
    return 1;
}

static void spi_release(void) {
    uint8_t discard;
    spi_read_byte(&discard, 0);
}

// Two filler bytes keep transfers word aligned
static int sd_send_command(uint8_t command, uint32_t argument, uint8_t crc) {
    uint32_t low = (uint32_t)(0x40 | command) | ((argument >> 24) & 0xff) << 8 |
                   ((argument >> 16) & 0xff) << 16 | ((argument >> 8) & 0xff) << 24;
    uint32_t high = (argument & 0xff) | (uint32_t)crc << 8 | 0xffu << 16 | 0xffu << 24;

    if (!spi_put_word(low) || !spi_put_word(high)) {
        return 0;
    }

    return spi_command(8, 1, QSPI_COMMAND_DIRECTION_TX);
}

static int sd_response(uint8_t* r1) {
    for (int attempt = 0; attempt < 32; attempt++) {
        uint8_t value;

        if (!spi_read_byte(&value, 1)) {
            return 0;
        }

        if (value != 0xff) {
            *r1 = value;
            return 1;
        }
    }

    return 0;
}

static int sd_init(void) {
    WRITE_REG(QSPI0->CONTROL, QSPI_CONTROL_SPIEN_BM | QSPI_CONTROL_OUTPUT_EN_BM);
    WRITE_REG(QSPI0->CONFIGOPTS[CS_CARD], CLKDIV_SLOW);
    WRITE_REG(QSPI0->CONFIGOPTS[CS_SPARE], CLKDIV_SLOW);

    // A dummy segment counts LEN in cycles
    spi_wait_idle();
    WRITE_REG(QSPI0->CSID, CS_SPARE);

    if (!spi_command(80, 0, QSPI_COMMAND_DIRECTION_DUMMY)) {
        return 0;
    }

    spi_wait_idle();
    WRITE_REG(QSPI0->CSID, CS_CARD);

    uint8_t r1;

    // Only CMD0 and CMD8 need real CRCs
    if (!sd_send_command(0, 0, 0x95) || !sd_response(&r1)) {
        return 0;
    }

    spi_release();

    if (r1 != 0x01) {
        return 0;
    }

    if (!sd_send_command(8, 0x1aa, 0x87) || !sd_response(&r1)) {
        return 0;
    }

    uint8_t r7[4];

    for (int i = 0; i < 4; i++) {
        if (!spi_read_byte(&r7[i], 1)) {
            return 0;
        }
    }

    spi_release();

    if (r1 != 0x01 || r7[3] != 0xaa) {
        return 0;
    }

    // ACMD41 until the card leaves idle
    for (int attempt = 0; attempt < 1024; attempt++) {
        if (!sd_send_command(55, 0, 0x01) || !sd_response(&r1)) {
            return 0;
        }

        spi_release();

        if (!sd_send_command(41, 0x40000000, 0x01) || !sd_response(&r1)) {
            return 0;
        }

        spi_release();

        if (r1 == 0x00) {
            WRITE_REG(QSPI0->CONFIGOPTS[CS_CARD], CLKDIV_FAST);
            return 1;
        }

        if (r1 != 0x01) {
            return 0;
        }
    }

    return 0;
}

// SDHC is block addressed, not byte
static int sd_read_block(uint32_t block, uint32_t* words) {
    uint8_t r1;

    if (!sd_send_command(17, block, 0x01) || !sd_response(&r1) || r1 != 0x00) {
        return 0;
    }

    // The card leads the block with 0xfe
    int found = 0;

    for (int attempt = 0; attempt < 1024 && !found; attempt++) {
        uint8_t value;

        if (!spi_read_byte(&value, 1)) {
            return 0;
        }

        if (value == 0xfe) {
            found = 1;
        } else if (value != 0xff) {
            return 0;
        }
    }

    if (!found) {
        return 0;
    }

    if (!spi_command(BLOCK_BYTES, 1, QSPI_COMMAND_DIRECTION_RX)) {
        return 0;
    }

    for (unsigned i = 0; i < BLOCK_WORDS; i++) {
        if (!spi_get_word(&words[i])) {
            return 0;
        }
    }

    uint8_t crc[2];

    for (int i = 0; i < 2; i++) {
        if (!spi_read_byte(&crc[i], 1)) {
            return 0;
        }
    }

    spi_release();
    return 1;
}

// Cache ways take the OCM at zero
extern char sd_tramp[], sd_tramp_end[];

__attribute__((naked, used)) static void tramp_blob(void) {
    __asm__ volatile(
        ".globl sd_tramp\n"
        "sd_tramp:\n"
        "   li t0, %0\n"
        "   li t1, %2\n"
        "   sw t1, 0(t0)\n"
        "   li a0, 0\n"               // hartid
        "   li a1, 0\n"               // no dtb, the image carries its own
        "   li t0, %1\n"
        "   jr t0\n"
        ".globl sd_tramp_end\n"
        "sd_tramp_end:\n" ::"i"(SCB_BASE + offsetof(SCB_TypeDef, LLCSEL)),
        "i"(RAM_BASE), "i"(LLC_WAYS));
}

// The debug module can read SCRATCH0
static void fail(uint32_t reason) {
    WRITE_REG(SCB->SCRATCH0, reason);

    for (;;) {
    }
}

void sd_main(void) {
    // The image expects mtime and UART running
    WRITE_REG(ACLINT->TICKTARGET, MTIME_HZ);
    WRITE_REG(ACLINT->TICKSOURCE, F_CPU);

    WRITE_REG(UART0->LCR, LCR_DLAB);
    WRITE_REG(UART0->DLL, UART_DIV);
    WRITE_REG(UART0->DLM, 0);
    WRITE_REG(UART0->LCR, LCR_8N1);

    if (!sd_init()) {
        fail(BAD_CARD);
    }

    uint32_t header[BLOCK_WORDS];

    if (!sd_read_block(0, header)) {
        fail(BAD_CARD);
    }

    uint32_t length = header[1];
    uint32_t expect = header[2];

    if (header[0] != MAGIC || length == 0 || length >= MAX_IMAGE) {
        fail(BAD_HEADER);
    }

    // The image starts on the next block
    uint32_t* dst = (uint32_t*)RAM_BASE;
    uint32_t words = (length + 3) / 4;
    uint32_t blocks = (words + BLOCK_WORDS - 1) / BLOCK_WORDS;

    for (uint32_t b = 0; b < blocks; b++) {
        if (!sd_read_block(1 + b, dst + b * BLOCK_WORDS)) {
            fail(BAD_CARD);
        }
    }

    uint32_t sum = 0;

    for (uint32_t i = 0; i < words; i++) {
        sum += dst[i];
    }

    if (sum != expect) {
        fail(BAD_CKSUM);
    }

    // Land the trampoline past the image
    uint8_t* tramp = (uint8_t*)(RAM_BASE + words * 4);

    for (char* p = sd_tramp; p < sd_tramp_end; p++) {
        *tramp++ = (uint8_t)*p;
    }

    __asm__ volatile("fence.i");
    ((void (*)(void))(RAM_BASE + words * 4))();
}

__attribute__((naked, section(".text.init"))) void _start(void) {
    __asm__ volatile(
        "li sp, %0\n"
        "call sd_main\n" ::"i"(STACK_TOP));
}

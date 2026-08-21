// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

// Boots an image off the SD card

#include <stdint.h>

#define SCB_SCRATCH 0x03000000u
#define UART0       0x03010000u
#define QSPI_BASE   0x03020000u
#define ACLINT_TICK 0x0200c000u
#define SCB_LLCSEL  0x0300000cu

#define RAM_BASE  0x80000000u
#define MAGIC     0x43535246u   // "FRSC", matches mkflash.py and fsbl.S
#define MAX_IMAGE 0x10000000u
// Top of the default OCM
#define STACK_TOP 0x00002000u

#define F_CPU     50000000u
#define BAUD      115200u
#define UART_DIV  ((F_CPU + 8 * BAUD) / (16 * BAUD))
#define MTIME_HZ  10000000u

#define UART_DLL 0x00
#define UART_DLM 0x04
#define UART_LCR 0x0c

#define SPI_CONTROL    (QSPI_BASE + 0x10)
#define SPI_STATUS     (QSPI_BASE + 0x14)
#define SPI_CONFIGOPTS (QSPI_BASE + 0x18)
#define SPI_CSID       (QSPI_BASE + 0x24)
#define SPI_COMMAND    (QSPI_BASE + 0x28)
#define SPI_RXDATA     (QSPI_BASE + 0x2c)
#define SPI_TXDATA     (QSPI_BASE + 0x30)

#define CTRL_SPIEN     (1u << 31)
#define CTRL_OUTPUT_EN (1u << 29)

#define ST_RXEMPTY (1u << 24)
#define ST_TXFULL  (1u << 29)
#define ST_ACTIVE  (1u << 30)
#define ST_READY   (1u << 31)

#define DIR_DUMMY 0u
#define DIR_RD    1u
#define DIR_WR    2u

#define CS_CARD  1u
#define CS_SPARE 2u

// SCK = core clock / (2 * (clkdiv + 1))
#define CLKDIV_SLOW 63u
#define CLKDIV_FAST 1u

#define BLOCK_BYTES 512u
#define BLOCK_WORDS (BLOCK_BYTES / 4)
#define SPIN_LIMIT  2000000u

// Odd, so never a real entry point
#define BAD_CARD   0xbad00011u
#define BAD_HEADER 0xbad00013u
#define BAD_CKSUM  0xbad00015u

static inline uint32_t rd(uint32_t addr) {
    return *(volatile uint32_t*)addr;
}

static inline void wr(uint32_t addr, uint32_t value) {
    *(volatile uint32_t*)addr = value;
}

static int spi_command(unsigned bytes, unsigned csaat, unsigned direction) {
    for (uint32_t i = 0; i < SPIN_LIMIT; i++) {
        if (rd(SPI_STATUS) & ST_READY) {
            wr(SPI_COMMAND, ((bytes - 1) & 0x1ff) | (csaat << 9) | (direction << 12));
            return 1;
        }
    }

    return 0;
}

// CSID only changes between transactions
static void spi_wait_idle(void) {
    for (uint32_t i = 0; i < SPIN_LIMIT; i++) {
        if (!(rd(SPI_STATUS) & ST_ACTIVE) && (rd(SPI_STATUS) & ST_READY)) {
            return;
        }
    }
}

static int spi_put_word(uint32_t value) {
    for (uint32_t i = 0; i < SPIN_LIMIT; i++) {
        if (!(rd(SPI_STATUS) & ST_TXFULL)) {
            wr(SPI_TXDATA, value);
            return 1;
        }
    }

    return 0;
}

static int spi_get_word(uint32_t* out) {
    for (uint32_t i = 0; i < SPIN_LIMIT; i++) {
        if (!(rd(SPI_STATUS) & ST_RXEMPTY)) {
            *out = rd(SPI_RXDATA);
            return 1;
        }
    }

    return 0;
}

// First byte in is the least significant
static int spi_read_byte(uint8_t* out, unsigned csaat) {
    uint32_t word;

    if (!spi_command(1, csaat, DIR_RD) || !spi_get_word(&word)) {
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

    return spi_command(8, 1, DIR_WR);
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
    wr(SPI_CONTROL, CTRL_SPIEN | CTRL_OUTPUT_EN);
    wr(SPI_CONFIGOPTS + 4 * CS_CARD, CLKDIV_SLOW);
    wr(SPI_CONFIGOPTS + 4 * CS_SPARE, CLKDIV_SLOW);

    // A dummy segment counts LEN in cycles
    spi_wait_idle();
    wr(SPI_CSID, CS_SPARE);

    if (!spi_command(80, 0, DIR_DUMMY)) {
        return 0;
    }

    spi_wait_idle();
    wr(SPI_CSID, CS_CARD);

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
            wr(SPI_CONFIGOPTS + 4 * CS_CARD, CLKDIV_FAST);
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

    if (!spi_command(BLOCK_BYTES, 1, DIR_RD)) {
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
        "   li t1, 0xf\n"             // every way a cache way
        "   sw t1, 0(t0)\n"
        "   li a0, 0\n"               // hartid
        "   li a1, 0\n"               // no dtb, the image carries its own
        "   li t0, %1\n"
        "   jr t0\n"
        ".globl sd_tramp_end\n"
        "sd_tramp_end:\n" ::"i"(SCB_LLCSEL), "i"(RAM_BASE));
}

// The debug module can read SCRATCH0
static void fail(uint32_t reason) {
    wr(SCB_SCRATCH, reason);

    for (;;) {
    }
}

void sd_main(void) {
    // The image expects mtime and UART running
    wr(ACLINT_TICK, MTIME_HZ);
    wr(ACLINT_TICK + 4, F_CPU);

    wr(UART0 + UART_LCR, 0x80);
    wr(UART0 + UART_DLL, UART_DIV);
    wr(UART0 + UART_DLM, 0);
    wr(UART0 + UART_LCR, 0x03);

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

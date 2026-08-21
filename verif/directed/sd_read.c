// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

// Reads blocks off an SD card

#include <stdint.h>

#define SCB_SCRATCH 0x03000000u
#define HALT        0x50000000u
#define PASS        0xaabbccddu

#define QSPI_BASE       0x03020000u
#define SPI_CONTROL     (QSPI_BASE + 0x10)
#define SPI_STATUS      (QSPI_BASE + 0x14)
#define SPI_CONFIGOPTS  (QSPI_BASE + 0x18)  // one per chip select, 4 bytes apart
#define SPI_CSID        (QSPI_BASE + 0x24)
#define SPI_COMMAND     (QSPI_BASE + 0x28)
#define SPI_RXDATA      (QSPI_BASE + 0x2c)
#define SPI_TXDATA      (QSPI_BASE + 0x30)

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

// Or'd into the scratch word on failure
enum {
    ERR_NONE = 0,
    ERR_CMD0, ERR_CMD8, ERR_ACMD41, ERR_CMD58, ERR_CMD16,
    ERR_CMD17, ERR_TOKEN, ERR_DATA, ERR_CRC, ERR_TIMEOUT,
};

#define SPIN_LIMIT 2000000u

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

static void spi_release(void) {
    uint8_t discard;
    spi_read_byte(&discard, 0);
}

static uint16_t crc16_ccitt(const uint8_t* data, unsigned length) {
    uint16_t crc = 0;

    for (unsigned i = 0; i < length; i++) {
        crc ^= (uint16_t)data[i] << 8;

        for (int bit = 0; bit < 8; bit++) {
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
        }
    }

    return crc;
}

static uint8_t pattern_byte(uint32_t block, unsigned offset) {
    return (uint8_t)(block * 31u + offset * 7u + 0x5au);
}

static int sd_init(void) {
    wr(SPI_CONTROL, CTRL_SPIEN | CTRL_OUTPUT_EN);
    wr(SPI_CONFIGOPTS + 4 * CS_CARD, CLKDIV_SLOW);
    wr(SPI_CONFIGOPTS + 4 * CS_SPARE, CLKDIV_SLOW);

    // A dummy segment counts LEN in cycles
    wr(SPI_CSID, CS_SPARE);

    if (!spi_command(80, 0, DIR_DUMMY)) {
        return ERR_TIMEOUT;
    }

    for (uint32_t i = 0; i < SPIN_LIMIT; i++) {
        if (!(rd(SPI_STATUS) & ST_ACTIVE)) {
            break;
        }
    }

    wr(SPI_CSID, CS_CARD);

    uint8_t r1;

    // Only CMD0 and CMD8 need real CRCs
    if (!sd_send_command(0, 0, 0x95) || !sd_response(&r1)) {
        return ERR_CMD0;
    }

    spi_release();

    if (r1 != 0x01) {
        return ERR_CMD0;
    }

    // Only a v2 card echoes the pattern
    if (!sd_send_command(8, 0x1aa, 0x87) || !sd_response(&r1)) {
        return ERR_CMD8;
    }

    uint8_t r7[4];

    for (int i = 0; i < 4; i++) {
        if (!spi_read_byte(&r7[i], 1)) {
            return ERR_CMD8;
        }
    }

    spi_release();

    if (r1 != 0x01 || r7[3] != 0xaa) {
        return ERR_CMD8;
    }

    // ACMD41 until the card leaves idle
    int ready = 0;

    for (int attempt = 0; attempt < 32 && !ready; attempt++) {
        if (!sd_send_command(55, 0, 0x01) || !sd_response(&r1)) {
            return ERR_ACMD41;
        }

        spi_release();

        if (!sd_send_command(41, 0x40000000, 0x01) || !sd_response(&r1)) {
            return ERR_ACMD41;
        }

        spi_release();

        if (r1 == 0x00) {
            ready = 1;
        } else if (r1 != 0x01) {
            return ERR_ACMD41;
        }
    }

    if (!ready) {
        return ERR_ACMD41;
    }

    // CCS set, so addresses are blocks
    if (!sd_send_command(58, 0, 0x01) || !sd_response(&r1)) {
        return ERR_CMD58;
    }

    uint8_t ocr[4];

    for (int i = 0; i < 4; i++) {
        if (!spi_read_byte(&ocr[i], 1)) {
            return ERR_CMD58;
        }
    }

    spi_release();

    if (r1 != 0x00 || !(ocr[0] & 0x40)) {
        return ERR_CMD58;
    }

    if (!sd_send_command(16, BLOCK_BYTES, 0x01) || !sd_response(&r1)) {
        return ERR_CMD16;
    }

    spi_release();

    if (r1 != 0x00) {
        return ERR_CMD16;
    }

    // Initialised, so speed up the bus
    wr(SPI_CONFIGOPTS + 4 * CS_CARD, CLKDIV_FAST);
    return ERR_NONE;
}

static int sd_read_block(uint32_t block, uint32_t* words) {
    uint8_t r1;

    if (!sd_send_command(17, block, 0x01) || !sd_response(&r1)) {
        return ERR_CMD17;
    }

    if (r1 != 0x00) {
        return ERR_CMD17;
    }

    // The card leads the block with 0xfe
    int found = 0;

    for (int attempt = 0; attempt < 64 && !found; attempt++) {
        uint8_t value;

        if (!spi_read_byte(&value, 1)) {
            return ERR_TOKEN;
        }

        if (value == 0xfe) {
            found = 1;
        } else if (value != 0xff) {
            return ERR_TOKEN;
        }
    }

    if (!found) {
        return ERR_TOKEN;
    }

    // One segment, drained as it arrives
    if (!spi_command(BLOCK_BYTES, 1, DIR_RD)) {
        return ERR_TIMEOUT;
    }

    for (unsigned i = 0; i < BLOCK_WORDS; i++) {
        if (!spi_get_word(&words[i])) {
            return ERR_DATA;
        }
    }

    uint8_t crc[2];

    for (int i = 0; i < 2; i++) {
        if (!spi_read_byte(&crc[i], 1)) {
            return ERR_CRC;
        }
    }

    spi_release();

    uint16_t expected = crc16_ccitt((const uint8_t*)words, BLOCK_BYTES);

    if ((uint16_t)(crc[0] << 8 | crc[1]) != expected) {
        return ERR_CRC;
    }

    return ERR_NONE;
}

static void finish(uint32_t value) {
    wr(SCB_SCRATCH, value);
    wr(HALT, 0);

    for (;;) {
    }
}

void sd_main(void) {
    int error = sd_init();

    if (error != ERR_NONE) {
        finish(0xf0000000u | (uint32_t)error);
    }

    uint32_t words[BLOCK_WORDS];

    for (uint32_t block = 0; block < 2; block++) {
        error = sd_read_block(block, words);

        if (error != ERR_NONE) {
            finish(0xf0000000u | (uint32_t)error);
        }

        const uint8_t* bytes = (const uint8_t*)words;

        for (unsigned i = 0; i < BLOCK_BYTES; i++) {
            if (bytes[i] != pattern_byte(block, i)) {
                finish(0xf0000000u | ERR_DATA);
            }
        }
    }

    finish(PASS);
}

__attribute__((naked, section(".text.init"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call sd_main\n");
}

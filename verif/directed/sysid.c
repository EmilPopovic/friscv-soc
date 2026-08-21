// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Emil Popović <mail@emilpopovic.me>

#include <stdint.h>
#include "vernii.h"

#define HALT (0x50000000u)
#define PASS (0xaabbccddu)

// Which check failed
enum {
    ERR_NONE = 0,
    ERR_MAGIC, ERR_SYSTEM, ERR_VARIANT, ERR_VER_RSVD,
    ERR_FEAT, ERR_CACHECFG, ERR_MMUCFG, ERR_IRQCFG, ERR_BUSCFG,
    ERR_BOOTSELW, ERR_ZSBLWORDS,
    ERR_OCMBASE, ERR_OCMSIZE, ERR_EXTBASE, ERR_EXTSIZE,
    ERR_CACHEDBASE, ERR_CACHEDSIZE,
    ERR_READONLY,
};

// Simulation parameters
#define SIM_OCM_BASE      (0x00000000u)
#define SIM_OCM_SIZE      (0x00002000u)
#define SIM_EXT_BASE      (0x80000000u)
#define SIM_EXT_SIZE      (0x01000000u)
#define SIM_LINE_BYTES    (32u)
#define SIM_WAYS          (4u)
#define SIM_ITLB_ENTRIES  (2u)
#define SIM_DTLB_ENTRIES  (4u)
#define SIM_EXT_IRQ       (2u)
#define SIM_GPIO_A_IRQ    (8u)
#define SIM_M_REG_RULES   (2u)
#define SIM_BOOT_SEL_W    (2u)

// Expected SYSFEAT
#define SIM_SYSFEAT (SCB_SYSFEAT_OCM_BM       | \
                     SCB_SYSFEAT_LLC_BM       | \
                     SCB_SYSFEAT_SRAMTAGS_BM  | \
                     SCB_SYSFEAT_MMU_BM       | \
                     SCB_SYSFEAT_ISAM_BM      | \
                     SCB_SYSFEAT_ISAA_BM      | \
                     SCB_SYSFEAT_ZSBLROM_BM   | \
                     SCB_SYSFEAT_HALTONEND_BM)

// Expected SYSMMUCFG
#define SIM_SYSMMUCFG ((SIM_ITLB_ENTRIES << SCB_SYSMMUCFG_ITLB_OFF) | \
                       (SIM_DTLB_ENTRIES << SCB_SYSMMUCFG_DTLB_OFF))

#define ZSBL_SLOT_WORDS (1024u)

static int check(void) {
    // Check SYSID magic value
    if (SCB->SYSID != SCB_SYSID_MAGIC_VALID) return ERR_MAGIC;

    // Check system identifies as Vernii
    if (READ_BIT(SCB->SYSIMPL, SCB_SYSIMPL_SYSTEM_BM) != SCB_SYSIMPL_SYSTEM_VERNII)
        return ERR_SYSTEM;
    // Check variant identifies as reference
    if (READ_BIT(SCB->SYSIMPL, SCB_SYSIMPL_VARIANT_BM) != SCB_SYSIMPL_VARIANT_REFERENCE)
        return ERR_VARIANT;

    // Check reserved bits are 0
    if ((SCB->SYSVER & 0x000000FEu) != 0) return ERR_VER_RSVD;

    // Check SYSFEAT matches expected feature set
    if (SCB->SYSFEAT != SIM_SYSFEAT) return ERR_FEAT;

    if (SCB->SYSCACHECFG !=
        ((SIM_LINE_BYTES << SCB_SYSCACHECFG_LINEBYTES_OFF) |
         (SIM_WAYS       << SCB_SYSCACHECFG_WAYS_OFF)))
        return ERR_CACHECFG;

    if (SCB->SYSMMUCFG != SIM_SYSMMUCFG) return ERR_MMUCFG;

    if (SCB->SYSIRQCFG !=
        ((SIM_EXT_IRQ    << SCB_SYSIRQCFG_EXTIRQ_OFF) |
         (SIM_GPIO_A_IRQ << SCB_SYSIRQCFG_GPIOAIRQ_OFF)))
        return ERR_IRQCFG;

    // AXI subordinate is disabled, there should be no rules
    if (SCB->SYSBUSCFG != (SIM_M_REG_RULES << SCB_SYSBUSCFG_MREGRULES_OFF))
        return ERR_BUSCFG;

    // Check boot select width
    if (READ_FIELD(SCB->SYSBOOTCFG, SCB_SYSBOOTCFG_BOOTSELW_BM,
                   SCB_SYSBOOTCFG_BOOTSELW_OFF) != SIM_BOOT_SEL_W)
        return ERR_BOOTSELW;

    uint32_t zsbl_words = READ_FIELD(SCB->SYSBOOTCFG, SCB_SYSBOOTCFG_ZSBLWORDS_BM,
                                     SCB_SYSBOOTCFG_ZSBLWORDS_OFF);
    if (zsbl_words == 0 || zsbl_words > ZSBL_SLOT_WORDS) return ERR_ZSBLWORDS;

    if (SCB->SYSOCMBASE    != SIM_OCM_BASE) return ERR_OCMBASE;
    if (SCB->SYSOCMSIZE    != SIM_OCM_SIZE) return ERR_OCMSIZE;
    if (SCB->SYSEXTBASE    != SIM_EXT_BASE) return ERR_EXTBASE;
    if (SCB->SYSEXTSIZE    != SIM_EXT_SIZE) return ERR_EXTSIZE;
    // CachedBase and CachedSize default to the external region
    if (SCB->SYSCACHEDBASE != SIM_EXT_BASE) return ERR_CACHEDBASE;
    if (SCB->SYSCACHEDSIZE != SIM_EXT_SIZE) return ERR_CACHEDSIZE;

    // The whole block is read-only, so a write must land nowhere
    volatile uint32_t *ident = (volatile uint32_t *)&SCB->SYSID;
    uint32_t before[15];

    for (unsigned i = 0; i < 15; i++) before[i] = ident[i];
    for (unsigned i = 0; i < 15; i++) ident[i] = ~before[i];

    for (unsigned i = 0; i < 15; i++) {
        if (ident[i] != before[i]) return ERR_READONLY;
    }

    return ERR_NONE;
}

static void finish(uint32_t value) {
    SCB->SCRATCH0 = value;
    *(volatile uint32_t *)HALT = 0;

    for (;;) {
    }
}

void sysid_main(void) {
    int error = check();

    finish(error == ERR_NONE ? PASS : (0xf0000000u | (uint32_t)error));
}

__attribute__((naked, section(".text.init"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call sysid_main\n");
}

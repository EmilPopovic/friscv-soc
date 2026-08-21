// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at
//
//     https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Emil Popović <mail@emilpopovic.me>

// Vernii SoC peripheral access layer header file

#ifndef __VERNII_H
#define __VERNII_H

#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

#include <stdint.h>

#define __I volatile const
#define __O volatile
#define __IO volatile

typedef union {  // reg64_t
    __IO uint64_t v;      // 64-bit value
    struct {
        __IO uint32_t L;  // LSW, offset +0x0
        __IO uint32_t H;  // MSW, offset +0x4
    };
} reg64_t;

///////////////////////////
// Peripheral memory map //
///////////////////////////

// Address space regions
#define OCM_BASE    ((uint32_t)0x00000000u)  // On-chip memory
#define ACLINT_BASE ((uint32_t)0x02000000u)  // Advanced Core Local Interruptor
#define PERIPH_BASE ((uint32_t)0x03000000u)  // Peripherals
#define PLIC_BASE   ((uint32_t)0x0C000000u)  // Platform-Level Interrupt Controller
#define EXT_BASE    ((uint32_t)0x80000000u)  // External address space

// Peripheral offsets from PERIPH_BASE
#define SCB_OFFSET   ((uint32_t)0x00000000u)  // System Control Block
#define UART0_OFFSET ((uint32_t)0x00010000u)  // UART0
#define QSPI0_OFFSET ((uint32_t)0x00020000u)  // QSPI0
#define GPIOA_OFFSET ((uint32_t)0x00030000u)  // GPIO Port A
#define ZSBL_OFFSET  ((uint32_t)0x00040000u)  // Zero-Stage Boot Loader
#define DM_OFFSET    ((uint32_t)0x00050000u)  // Debug Module

// Peripheral base addresses
#define SCB_BASE   (PERIPH_BASE + SCB_OFFSET)
#define UART0_BASE (PERIPH_BASE + UART0_OFFSET)
#define QSPI0_BASE (PERIPH_BASE + QSPI0_OFFSET)
#define GPIOA_BASE (PERIPH_BASE + GPIOA_OFFSET)
#define ZSBL_BASE  (PERIPH_BASE + ZSBL_OFFSET)
#define DM_BASE    (PERIPH_BASE + DM_OFFSET)

// Peripheral memory map

////////////////////////////////////
// Peripheral register structures //
////////////////////////////////////

// Advanced Core Local Interruptor

typedef struct {  // ACLINT_TypeDef
    __IO uint32_t MSIP[4095];       // 0x0000 + 4*hartidx MSIP Machine-mode software interrupt pending
    uint32_t      RESERVED0;        // 0x3FFC - 0x4000 Reserved
    reg64_t       MTIMECMP[4095];   // 0x4000 + 8*hartidx MTIMECMP Machine-mode timer compare
    reg64_t       MTIME;            // 0xBFF8 MTIME Machine-mode timer
    __IO uint32_t TICKTARGET;       // 0xC000 TICKTARGET Target rate register
    __IO uint32_t TICKSOURCE;       // 0xC004 TICKSOURCE Source rate register
    uint32_t      RESERVED1[4094];  // 0xC008 - 0xFFFF Reserved
    __O  uint32_t SETSSIP[4095];    // 0x10000 + 4*hartidx SETSSIP Set supervisor-mode software interrupt pending
} ACLINT_TypeDef;

// System Control Block

typedef struct {  // SCB_TypeDef
    __IO uint32_t SCRATCH0;         // 0x000 SCB Scratch register 0
    __I  uint32_t BOOTSEL;          // 0x004 SCB Boot select register
    uint32_t      RESERVED0[1];     // 0x008 - 0x00B Reserved
    __IO uint32_t LLCSEL;           // 0x00C SCB Last-level cache way select
    __IO uint32_t LLCCRPSEL;        // 0x010 SCB LLC replacement policy select
    __IO uint32_t LLCINV;           // 0x014 SCB LLC invalidate all cache lines
    reg64_t       LLCRDACC;         // 0x018 SCB LLC read access count
    reg64_t       LLCRDMISS;        // 0x020 SCB LLC read miss count
    reg64_t       LLCRDWRACC;       // 0x028 SCB LLC write access count
    uint32_t      RESERVED1[52];    // 0x030 - 0x0FF Reserved
    __I  uint32_t SYSID;            // 0x100 SCB Identification block magic
    __I  uint32_t SYSIMPL;          // 0x104 SCB Which system, which build of it
    __I  uint32_t SYSVER;           // 0x108 SCB System version
    __I  uint32_t SYSFEAT;          // 0x10C SCB Features this build has
    __I  uint32_t SYSCACHECFG;      // 0x110 SCB OCM and LLC geometry
    __I  uint32_t SYSMMUCFG;        // 0x114 SCB TLB and PMP table sizes
    __I  uint32_t SYSIRQCFG;        // 0x118 SCB Interrupt lines wired to the PLIC
    __I  uint32_t SYSBUSCFG;        // 0x11C SCB Integrator bus rule counts
    __I  uint32_t SYSBOOTCFG;       // 0x120 SCB Boot ROM and boot select sizes
    __I  uint32_t SYSOCMBASE;       // 0x124 SCB OCM base address
    __I  uint32_t SYSOCMSIZE;       // 0x128 SCB OCM size in bytes
    __I  uint32_t SYSEXTBASE;       // 0x12C SCB External memory base address
    __I  uint32_t SYSEXTSIZE;       // 0x130 SCB External memory size in bytes
    __I  uint32_t SYSCACHEDBASE;    // 0x134 SCB Cached window base address
    __I  uint32_t SYSCACHEDSIZE;    // 0x138 SCB Cached window size in bytes
} SCB_TypeDef;

// Universal Asynchronous Receiver/Transmitter

typedef struct {  // UART_TypeDef
    union {
        __IO uint32_t RBR;  // 0x00 R  DLAB=0 Rx buffer
        __IO uint32_t THR;  // 0x00 W  DLAB=0 Tx holding
        __IO uint32_t DLL;  // 0x00 RW DLAB=1 Divisor low
    };
    union {
        __IO uint32_t IER;  // 0x04 RW DLAB=0 Interrupt enable
        __IO uint32_t DLM;  // 0x04 RW DLAB=1 Divisor high
    };
    union {
        __IO uint32_t IIR;  // 0x08 R  Interrupt ID
        __IO uint32_t FCR;  // 0x08 W  FIFO control
    };
    __IO uint32_t LCR;      // 0x0C RW Line control
    __IO uint32_t MCR;      // 0x10 RW Modem control
    __I  uint32_t LSR;      // 0x14 R  Line status
    __I  uint32_t MSR;      // 0x18 R  Modem status
    __IO uint32_t SCR;      // 0x1C RW Scratch
} UART_TypeDef;

// Quad Serial Peripheral Interface

typedef struct {  // QSPI_TypeDef
    __IO uint32_t INTR_STATE;    // 0x00 RW Interrupt State Register
    __IO uint32_t INTR_ENABLE;   // 0x04 RW Interrupt Enable Register
    __O  uint32_t INTR_TEST;     // 0x08 W  Interrupt Test Register
    __O  uint32_t ALERT_TEST;    // 0x0C W  Alert Test Register
    __IO uint32_t CONTROL;       // 0x10 RW Control register
    __I  uint32_t STATUS;        // 0x14 R  Status register
    __IO uint32_t CONFIGOPTS;    // 0x18 RW Configuration options register
    __IO uint32_t CSID;          // 0x1C RW Chip-Select ID
    __O  uint32_t COMMAND;       // 0x20 W  Command Register
    __I  uint32_t RXDATA;        // 0x24 R  SPI Receive Data
    __O  uint32_t TXDATA;        // 0x28 W  SPI Transmit Data
    __IO uint32_t ERROR_ENABLE;  // 0x2C RW Controls which classes of errors raise an interrupt
    __IO uint32_t ERROR_STATUS;  // 0x30 RW Indicates that any errors that have occurred
    __IO uint32_t EVENT_ENABLE;  // 0x34 RW Controls which classes of SPI events raise an interrupt
} QSPI_TypeDef;

// General Purpose Input/Output

typedef struct {  // GPIO_TypeDef
    __IO uint32_t INTR_STATE;               // 0x00 RW Interrupt State Register
    __IO uint32_t INTR_ENABLE;              // 0x04 RW Interrupt Enable Register
    __O  uint32_t INTR_TEST;                // 0x08 W  Interrupt Test Register
    __O  uint32_t ALERT_TEST;               // 0x0C W  Alert Test Register
    __I  uint32_t DATA_IN;                  // 0x10 R  GPIO Input data read value
    __IO uint32_t DIRECT_OUT;               // 0x14 RW GPIO direct output data write value
    __IO uint32_t MASKED_OUT_LOWER;         // 0x18 31:16 W, 15:0 RW GPIO write data lower with mask
    __IO uint32_t MASKED_OUT_UPPER;         // 0x1C 31:16 W, 15:0 RW GPIO write data upper with mask
    __IO uint32_t DIRECT_OE;                // 0x20 RW GPIO Output Enable
    __IO uint32_t MASKED_OE_LOWER;          // 0x24 RW GPIO write Output Enable lower with mask
    __IO uint32_t MASKED_OE_UPPER;          // 0x28 RW GPIO write Output Enable upper with mask
    __IO uint32_t INTR_CTRL_EN_RISING;      // 0x2C RW GPIO interrupt enable for GPIO, rising edge
    __IO uint32_t INTR_CTRL_EN_FALLING;     // 0x30 RW GPIO interrupt enable for GPIO, falling edge
    __IO uint32_t INTR_CTRL_EN_LVLHIGH;     // 0x34 RW GPIO interrupt enable for GPIO, level high
    __IO uint32_t INTR_CTRL_EN_LVLLOW;      // 0x38 RW GPIO interrupt enable for GPIO, level low
    __IO uint32_t CTRL_EN_INPUT_FILTER;     // 0x3C RW filter enable for GPIO input bits
    __I  uint32_t HW_STRAPS_DATA_IN_VALID;  // 0x40 R  Indicates whether the data in HW_STRAPS_DATA_IN is valid
    __I  uint32_t HW_STRAPS_DATA_IN;        // 0x44 R  GPIO input data that was sampled as straps at most once after the block came out of reset
} GPIO_TypeDef;

// Debug Module

typedef struct {  // DM_TypeDef
    // TODO
} DM_TypeDef;

// Platform-Level Interrupt Controller

typedef struct {  // PLIC_TypeDef
    // TODO
} PLIC_TypeDef;

// Peripheral register structures

/////////////////////////////
// Peripheral declarations //
/////////////////////////////

#define OCM     ((uint32_t *) OCM_BASE)
#define ACLINT  ((ACLINT_TypeDef *) ACLINT_BASE)
#define SCB     ((SCB_TypeDef *) SCB_BASE)
#define UART0   ((UART_TypeDef *) UART0_BASE)
#define QSPI0   ((QSPI_TypeDef *) QSPI0_BASE)
#define GPIOA   ((GPIO_TypeDef *) GPIOA_BASE)
#define ZSBL    ((uint32_t *) ZSBL_BASE)
#define DM      ((DM_TypeDef *) DM_BASE)
#define PLIC    ((PLIC_TypeDef *) PLIC_BASE)
#define EXT     ((uint32_t *) EXT_BASE)

// Peripheral declarations

/////////////////////////////////////////
// Peripheral register bits definition //
/////////////////////////////////////////

// Bit definitions for SCB

// BOOTSEL (0x04) reset X
#define SCB_BOOTSEL_BOOT0_BM       ((uint32_t)0x00000001u)  // Boot select bit 0 bit mask
#define SCB_BOOTSEL_BOOT0_OFF      ((uint32_t)0x00000000u)  // Boot select bit 0 offset
#define SCB_BOOTSEL_BOOT1_BM       ((uint32_t)0x00000002u)  // Boot select bit 1 bit mask
#define SCB_BOOTSEL_BOOT1_OFF      ((uint32_t)0x00000001u)  // Boot select bit 1 offset
#define SCB_BOOTSEL_BOOT2_BM       ((uint32_t)0x00000004u)  // Boot select bit 2 bit mask
#define SCB_BOOTSEL_BOOT2_OFF      ((uint32_t)0x00000002u)  // Boot select bit 2 offset
#define SCB_BOOTSEL_BOOT3_BM       ((uint32_t)0x00000008u)  // Boot select bit 3 bit mask
#define SCB_BOOTSEL_BOOT3_OFF      ((uint32_t)0x00000003u)  // Boot select bit 3 offset

// LLCSEL (0x0C) reset 0x00000000
#define SCB_LLCSEL_WAY0_LLC_EN_BM  ((uint32_t)0x00000001u)  // Set way 0 to cache bit mask
#define SCB_LLCSEL_WAY0_LLC_EN_OFF ((uint32_t)0x00000000u)  // Set way 0 to cache offset
#define SCB_LLCSEL_WAY1_LLC_EN_BM  ((uint32_t)0x00000002u)  // Set way 1 to cache bit mask
#define SCB_LLCSEL_WAY1_LLC_EN_OFF ((uint32_t)0x00000001u)  // Set way 1 to cache offset
#define SCB_LLCSEL_WAY2_LLC_EN_BM  ((uint32_t)0x00000004u)  // Set way 2 to cache bit mask
#define SCB_LLCSEL_WAY2_LLC_EN_OFF ((uint32_t)0x00000002u)  // Set way 2 to cache offset
#define SCB_LLCSEL_WAY3_LLC_EN_BM  ((uint32_t)0x00000008u)  // Set way 3 to cache bit mask
#define SCB_LLCSEL_WAY3_LLC_EN_OFF ((uint32_t)0x00000003u)  // Set way 3 to cache offset
#define SCB_LLCSEL_WAY4_LLC_EN_BM  ((uint32_t)0x00000010u)  // Set way 4 to cache bit mask
#define SCB_LLCSEL_WAY4_LLC_EN_OFF ((uint32_t)0x00000004u)  // Set way 4 to cache offset
#define SCB_LLCSEL_WAY5_LLC_EN_BM  ((uint32_t)0x00000020u)  // Set way 5 to cache bit mask
#define SCB_LLCSEL_WAY5_LLC_EN_OFF ((uint32_t)0x00000005u)  // Set way 5 to cache offset
#define SCB_LLCSEL_WAY6_LLC_EN_BM  ((uint32_t)0x00000040u)  // Set way 6 to cache bit mask
#define SCB_LLCSEL_WAY6_LLC_EN_OFF ((uint32_t)0x00000006u)  // Set way 6 to cache offset
#define SCB_LLCSEL_WAY7_LLC_EN_BM  ((uint32_t)0x00000080u)  // Set way 7 to cache bit mask
#define SCB_LLCSEL_WAY7_LLC_EN_OFF ((uint32_t)0x00000007u)  // Set way 7 to cache offset

// LLCCRPSEL (0x10) reset 0x00000000
#define SCB_LLCCRPSEL_CRP_BM       ((uint32_t)0x00000001u)  // LLC replacement policy bit mask
#define SCB_LLCCRPSEL_CRP_OFF      ((uint32_t)0x00000000u)  // LLC replacement policy offset
#define SCB_LLCCRPSEL_CRP_RR       ((uint32_t)0x00000000u)  // Round-robin replacement policy
#define SCB_LLCCRPSEL_CRP_RAND     ((uint32_t)0x00000001u)  // LFSR-based random replacement policy

// SYSID (0x100) reset 0x5645524E
#define SCB_SYSID_MAGIC_BM            ((uint32_t)0xFFFFFFFFu)  // Identification block magic bit mask
#define SCB_SYSID_MAGIC_OFF           ((uint32_t)0x00000000u)  // Identification block magic offset
#define SCB_SYSID_MAGIC_VALID         ((uint32_t)0x5645524Eu)  // "VERN", the valid magic value

// SYSIMPL (0x104) reset X
#define SCB_SYSIMPL_SYSTEM_BM         ((uint32_t)0xFFFF0000u)  // Which system of the family bit mask
#define SCB_SYSIMPL_SYSTEM_OFF        ((uint32_t)0x00000010u)  // Which system of the family offset
#define SCB_SYSIMPL_SYSTEM_VERNII     ((uint32_t)0x00010000u)  // Vernii, not later compatible version
#define SCB_SYSIMPL_VARIANT_BM        ((uint32_t)0x0000FFFFu)  // Integrator-assigned build variant bit mask
#define SCB_SYSIMPL_VARIANT_OFF       ((uint32_t)0x00000000u)  // Integrator-assigned build variant offset
#define SCB_SYSIMPL_VARIANT_REFERENCE ((uint32_t)0x00000000u)  // The reference configuration

// SYSVER (0x108) reset X
#define SCB_SYSVER_MAJOR_BM           ((uint32_t)0xFF000000u)  // Major version bit mask
#define SCB_SYSVER_MAJOR_OFF          ((uint32_t)0x00000018u)  // Major version offset
#define SCB_SYSVER_MINOR_BM           ((uint32_t)0x00FF0000u)  // Minor version bit mask
#define SCB_SYSVER_MINOR_OFF          ((uint32_t)0x00000010u)  // Minor version offset
#define SCB_SYSVER_PATCH_BM           ((uint32_t)0x0000FF00u)  // Patch version bit mask
#define SCB_SYSVER_PATCH_OFF          ((uint32_t)0x00000008u)  // Patch version offset
#define SCB_SYSVER_REL_BM             ((uint32_t)0x00000001u)  // Set if this is that release, clear if it has unreleased changes
#define SCB_SYSVER_REL_OFF            ((uint32_t)0x00000000u)  // Release offset

// SYSFEAT (0x10C) reset X
#define SCB_SYSFEAT_OCM_BM            ((uint32_t)0x00000001u)  // On-chip memory present bit mask
#define SCB_SYSFEAT_OCM_OFF           ((uint32_t)0x00000000u)  // On-chip memory present offset
#define SCB_SYSFEAT_LLC_BM            ((uint32_t)0x00000002u)  // LLC present, LLC* registers usable bit mask
#define SCB_SYSFEAT_LLC_OFF           ((uint32_t)0x00000001u)  // LLC present offset
#define SCB_SYSFEAT_SRAMTAGS_BM       ((uint32_t)0x00000004u)  // LLC tags in SRAM bit mask
#define SCB_SYSFEAT_SRAMTAGS_OFF      ((uint32_t)0x00000002u)  // LLC tags in SRAM offset
#define SCB_SYSFEAT_MMU_BM            ((uint32_t)0x00000010u)  // MMU present bit mask
#define SCB_SYSFEAT_MMU_OFF           ((uint32_t)0x00000004u)  // MMU present offset
#define SCB_SYSFEAT_FINETLBFLUSH_BM   ((uint32_t)0x00000020u)  // sfence.vma with rs1 flushes one entry bit mask
#define SCB_SYSFEAT_FINETLBFLUSH_OFF  ((uint32_t)0x00000005u)  // sfence.vma with rs1 flushes one entry offset
#define SCB_SYSFEAT_PMP_BM            ((uint32_t)0x00000040u)  // PMP enforced bit mask
#define SCB_SYSFEAT_PMP_OFF           ((uint32_t)0x00000006u)  // PMP enforced offset
#define SCB_SYSFEAT_PTWPMP_BM         ((uint32_t)0x00000080u)  // PMP enforced on page table walks bit mask
#define SCB_SYSFEAT_PTWPMP_OFF        ((uint32_t)0x00000007u)  // PMP enforced on page table walks offset
#define SCB_SYSFEAT_ISAE_BM           ((uint32_t)0x00000100u)  // RV32E register file bit mask
#define SCB_SYSFEAT_ISAE_OFF          ((uint32_t)0x00000008u)  // RV32E register file offset
#define SCB_SYSFEAT_ISAM_BM           ((uint32_t)0x00000200u)  // M extension bit mask
#define SCB_SYSFEAT_ISAM_OFF          ((uint32_t)0x00000009u)  // M extension offset
#define SCB_SYSFEAT_ISAA_BM           ((uint32_t)0x00000400u)  // A extension bit mask
#define SCB_SYSFEAT_ISAA_OFF          ((uint32_t)0x0000000Au)  // A extension offset
#define SCB_SYSFEAT_FASTMUL_BM        ((uint32_t)0x00000800u)  // Single-cycle multiplier bit mask
#define SCB_SYSFEAT_FASTMUL_OFF       ((uint32_t)0x0000000Bu)  // Single-cycle multiplier offset
#define SCB_SYSFEAT_ZSBLROM_BM        ((uint32_t)0x00001000u)  // Integrated boot ROM bit mask
#define SCB_SYSFEAT_ZSBLROM_OFF       ((uint32_t)0x0000000Cu)  // Integrated boot ROM offset
#define SCB_SYSFEAT_SAXIGP_BM         ((uint32_t)0x00002000u)  // General-purpose AXI Lite subordinate port enabled bit mask
#define SCB_SYSFEAT_SAXIGP_OFF        ((uint32_t)0x0000000Du)  // General-purpose AXI Lite subordinate port enabled offset
#define SCB_SYSFEAT_HALTONEND_BM      ((uint32_t)0x00010000u)  // Core halts on the end marker bit mask
#define SCB_SYSFEAT_HALTONEND_OFF     ((uint32_t)0x00000010u)  // Core halts on the end marker offset

// SYSCACHECFG (0x110) reset X
#define SCB_SYSCACHECFG_LINEBYTES_BM  ((uint32_t)0x0000FFFFu)  // Bytes per LLC line bit mask
#define SCB_SYSCACHECFG_LINEBYTES_OFF ((uint32_t)0x00000000u)  // Bytes per LLC line offset
#define SCB_SYSCACHECFG_WAYS_BM       ((uint32_t)0x00FF0000u)  // OCM/LLC ways bit mask
#define SCB_SYSCACHECFG_WAYS_OFF      ((uint32_t)0x00000010u)  // OCM/LLC ways offset

// SYSMMUCFG (0x114) reset X
#define SCB_SYSMMUCFG_ITLB_BM         ((uint32_t)0x000000FFu)  // Instruction TLB entries bit mask
#define SCB_SYSMMUCFG_ITLB_OFF        ((uint32_t)0x00000000u)  // Instruction TLB entries offset
#define SCB_SYSMMUCFG_DTLB_BM         ((uint32_t)0x0000FF00u)  // Data TLB entries bit mask
#define SCB_SYSMMUCFG_DTLB_OFF        ((uint32_t)0x00000008u)  // Data TLB entries offset
#define SCB_SYSMMUCFG_PMP_BM          ((uint32_t)0x00FF0000u)  // Usable pmpcfg/pmpaddr entries bit mask
#define SCB_SYSMMUCFG_PMP_OFF         ((uint32_t)0x00000010u)  // Usable pmpcfg/pmpaddr entries offset

// SYSIRQCFG (0x118) reset X
#define SCB_SYSIRQCFG_EXTIRQ_BM       ((uint32_t)0x000000FFu)  // External lines wired to the PLIC bit mask
#define SCB_SYSIRQCFG_EXTIRQ_OFF      ((uint32_t)0x00000000u)  // External lines wired to the PLIC offset
#define SCB_SYSIRQCFG_GPIOAIRQ_BM     ((uint32_t)0x0000FF00u)  // GPIO port A lines wired to the PLIC bit mask
#define SCB_SYSIRQCFG_GPIOAIRQ_OFF    ((uint32_t)0x00000008u)  // GPIO port A lines wired to the PLIC offset

// SYSBUSCFG (0x11C) reset X
#define SCB_SYSBUSCFG_MREGRULES_BM    ((uint32_t)0x000000FFu)  // Populated manager register bus rules bit mask
#define SCB_SYSBUSCFG_MREGRULES_OFF   ((uint32_t)0x00000000u)  // Populated manager register bus rules offset
#define SCB_SYSBUSCFG_SAXIGPRULES_BM  ((uint32_t)0x0000FF00u)  // Populated GP subordinate rules bit mask
#define SCB_SYSBUSCFG_SAXIGPRULES_OFF ((uint32_t)0x00000008u)  // Populated GP subordinate rules offset

// SYSBOOTCFG (0x120) reset X
#define SCB_SYSBOOTCFG_ZSBLWORDS_BM   ((uint32_t)0x0000FFFFu)  // Words of boot ROM image bit mask
#define SCB_SYSBOOTCFG_ZSBLWORDS_OFF  ((uint32_t)0x00000000u)  // Words of boot ROM image offset
#define SCB_SYSBOOTCFG_BOOTSELW_BM    ((uint32_t)0x00FF0000u)  // Boot select pads bit mask
#define SCB_SYSBOOTCFG_BOOTSELW_OFF   ((uint32_t)0x00000010u)  // Boot select pads offset

// Bit definitions for UART

// TODO

// Bit definitions for QSPI
//
// Field layout follows OpenTitan spi_host:
// https://opentitan.org/book/hw/ip/spi_host/doc/registers.html

// INTR_STATE (0x00) reset 0x00000000
#define QSPI_INTR_STATE_SPI_EVENT_BM      ((uint32_t)0x00000002u)  // SPI event interrupt state (ro) bit mask
#define QSPI_INTR_STATE_SPI_EVENT_OFF     ((uint32_t)0x00000001u)  // SPI event interrupt state offset
#define QSPI_INTR_STATE_SPI_ERROR_BM      ((uint32_t)0x00000001u)  // SPI error interrupt state (rw1c) bit mask
#define QSPI_INTR_STATE_SPI_ERROR_OFF     ((uint32_t)0x00000000u)  // SPI error interrupt state offset

// INTR_ENABLE (0x04) reset 0x00000000
#define QSPI_INTR_ENABLE_SPI_EVENT_BM     ((uint32_t)0x00000002u)  // SPI event interrupt enable bit mask
#define QSPI_INTR_ENABLE_SPI_EVENT_OFF    ((uint32_t)0x00000001u)  // SPI event interrupt enable offset
#define QSPI_INTR_ENABLE_SPI_ERROR_BM     ((uint32_t)0x00000001u)  // SPI error interrupt enable bit mask
#define QSPI_INTR_ENABLE_SPI_ERROR_OFF    ((uint32_t)0x00000000u)  // SPI error interrupt enable offset

// INTR_TEST (0x08) reset 0x00000000
#define QSPI_INTR_TEST_SPI_EVENT_BM       ((uint32_t)0x00000002u)  // SPI event interrupt test bit mask
#define QSPI_INTR_TEST_SPI_EVENT_OFF      ((uint32_t)0x00000001u)  // SPI event interrupt test offset
#define QSPI_INTR_TEST_SPI_ERROR_BM       ((uint32_t)0x00000001u)  // SPI error interrupt test bit mask
#define QSPI_INTR_TEST_SPI_ERROR_OFF      ((uint32_t)0x00000000u)  // SPI error interrupt test offset

// ALERT_TEST (0x0C) reset 0x00000000
#define QSPI_ALERT_TEST_FATAL_FAULT_BM    ((uint32_t)0x00000001u)  // Fatal fault alert test bit mask
#define QSPI_ALERT_TEST_FATAL_FAULT_OFF   ((uint32_t)0x00000000u)  // Fatal fault alert test offset

// CONTROL (0x10) reset 0x0000007F
#define QSPI_CONTROL_SPIEN_BM             ((uint32_t)0x80000000u)  // SPI host enable bit mask
#define QSPI_CONTROL_SPIEN_OFF            ((uint32_t)0x0000001Fu)  // SPI host enable offset
#define QSPI_CONTROL_SW_RST_BM            ((uint32_t)0x40000000u)  // Software reset of internal state bit mask
#define QSPI_CONTROL_SW_RST_OFF           ((uint32_t)0x0000001Eu)  // Software reset of internal state offset
#define QSPI_CONTROL_OUTPUT_EN_BM         ((uint32_t)0x20000000u)  // sck/csb/sd output buffer enable bit mask
#define QSPI_CONTROL_OUTPUT_EN_OFF        ((uint32_t)0x0000001Du)  // sck/csb/sd output buffer enable offset
#define QSPI_CONTROL_TX_WATERMARK_BM      ((uint32_t)0x0000FF00u)  // TX FIFO watermark, 32b words bit mask
#define QSPI_CONTROL_TX_WATERMARK_OFF     ((uint32_t)0x00000008u)  // TX FIFO watermark, 32b words offset
#define QSPI_CONTROL_RX_WATERMARK_BM      ((uint32_t)0x000000FFu)  // RX FIFO watermark, 32b words bit mask
#define QSPI_CONTROL_RX_WATERMARK_OFF     ((uint32_t)0x00000000u)  // RX FIFO watermark, 32b words offset

// STATUS (0x14) reset 0x00000000
#define QSPI_STATUS_READY_BM              ((uint32_t)0x80000000u)  // Ready to accept a command bit mask
#define QSPI_STATUS_READY_OFF             ((uint32_t)0x0000001Fu)  // Ready to accept a command offset
#define QSPI_STATUS_ACTIVE_BM             ((uint32_t)0x40000000u)  // Command in progress bit mask
#define QSPI_STATUS_ACTIVE_OFF            ((uint32_t)0x0000001Eu)  // Command in progress offset
#define QSPI_STATUS_TXFULL_BM             ((uint32_t)0x20000000u)  // TX FIFO full bit mask
#define QSPI_STATUS_TXFULL_OFF            ((uint32_t)0x0000001Du)  // TX FIFO full offset
#define QSPI_STATUS_TXEMPTY_BM            ((uint32_t)0x10000000u)  // TX FIFO empty bit mask
#define QSPI_STATUS_TXEMPTY_OFF           ((uint32_t)0x0000001Cu)  // TX FIFO empty offset
#define QSPI_STATUS_TXSTALL_BM            ((uint32_t)0x08000000u)  // Transaction stalled, TX FIFO starved bit mask
#define QSPI_STATUS_TXSTALL_OFF           ((uint32_t)0x0000001Bu)  // Transaction stalled, TX FIFO starved offset
#define QSPI_STATUS_TXWM_BM               ((uint32_t)0x04000000u)  // TX FIFO below CTRL.TX_WATERMARK bit mask
#define QSPI_STATUS_TXWM_OFF              ((uint32_t)0x0000001Au)  // TX FIFO below CTRL.TX_WATERMARK offset
#define QSPI_STATUS_RXFULL_BM             ((uint32_t)0x02000000u)  // RX FIFO full bit mask
#define QSPI_STATUS_RXFULL_OFF            ((uint32_t)0x00000019u)  // RX FIFO full offset
#define QSPI_STATUS_RXEMPTY_BM            ((uint32_t)0x01000000u)  // RX FIFO empty bit mask
#define QSPI_STATUS_RXEMPTY_OFF           ((uint32_t)0x00000018u)  // RX FIFO empty offset
#define QSPI_STATUS_RXSTALL_BM            ((uint32_t)0x00800000u)  // Transaction stalled, RX FIFO full bit mask
#define QSPI_STATUS_RXSTALL_OFF           ((uint32_t)0x00000017u)  // Transaction stalled, RX FIFO full offset
#define QSPI_STATUS_BYTEORDER_BM          ((uint32_t)0x00400000u)  // Value of the ByteOrder parameter bit mask
#define QSPI_STATUS_BYTEORDER_OFF         ((uint32_t)0x00000016u)  // Value of the ByteOrder parameter offset
#define QSPI_STATUS_RXWM_BM               ((uint32_t)0x00100000u)  // RX FIFO above CTRL.RX_WATERMARK bit mask
#define QSPI_STATUS_RXWM_OFF              ((uint32_t)0x00000014u)  // RX FIFO above CTRL.RX_WATERMARK offset
#define QSPI_STATUS_CMDQD_BM              ((uint32_t)0x000F0000u)  // Command queue depth, 32b words bit mask
#define QSPI_STATUS_CMDQD_OFF             ((uint32_t)0x00000010u)  // Command queue depth, 32b words offset
#define QSPI_STATUS_RXQD_BM               ((uint32_t)0x0000FF00u)  // RX queue depth, 32b words bit mask
#define QSPI_STATUS_RXQD_OFF              ((uint32_t)0x00000008u)  // RX queue depth, 32b words offset
#define QSPI_STATUS_TXQD_BM               ((uint32_t)0x000000FFu)  // TX queue depth, 32b words bit mask
#define QSPI_STATUS_TXQD_OFF              ((uint32_t)0x00000000u)  // TX queue depth, 32b words offset

// CONFIGOPTS (0x18) reset 0x00000000
#define QSPI_CONFIGOPTS_CPOL_BM           ((uint32_t)0x80000000u)  // sck idle polarity bit mask
#define QSPI_CONFIGOPTS_CPOL_OFF          ((uint32_t)0x0000001Fu)  // sck idle polarity offset
#define QSPI_CONFIGOPTS_CPOL_IDLE_LOW     ((uint32_t)0x00000000u)  // sck low when idle
#define QSPI_CONFIGOPTS_CPOL_IDLE_HIGH    ((uint32_t)0x80000000u)  // sck high when idle
#define QSPI_CONFIGOPTS_CPHA_BM           ((uint32_t)0x40000000u)  // sck phase relative to data bit mask
#define QSPI_CONFIGOPTS_CPHA_OFF          ((uint32_t)0x0000001Eu)  // sck phase relative to data offset
#define QSPI_CONFIGOPTS_FULLCYC_BM        ((uint32_t)0x20000000u)  // Sample a full cycle after shift bit mask
#define QSPI_CONFIGOPTS_FULLCYC_OFF       ((uint32_t)0x0000001Du)  // Sample a full cycle after shift offset
#define QSPI_CONFIGOPTS_CSNLEAD_BM        ((uint32_t)0x0F000000u)  // cs_n lead, CSNLEAD+1 half sck cycles bit mask
#define QSPI_CONFIGOPTS_CSNLEAD_OFF       ((uint32_t)0x00000018u)  // cs_n lead, CSNLEAD+1 half sck cycles offset
#define QSPI_CONFIGOPTS_CSNTRAIL_BM       ((uint32_t)0x00F00000u)  // cs_n trail, CSNTRAIL+1 half sck cycles bit mask
#define QSPI_CONFIGOPTS_CSNTRAIL_OFF      ((uint32_t)0x00000014u)  // cs_n trail, CSNTRAIL+1 half sck cycles offset
#define QSPI_CONFIGOPTS_CSNIDLE_BM        ((uint32_t)0x000F0000u)  // cs_n idle, CSNIDLE+1 half sck cycles bit mask
#define QSPI_CONFIGOPTS_CSNIDLE_OFF       ((uint32_t)0x00000010u)  // cs_n idle, CSNIDLE+1 half sck cycles offset
#define QSPI_CONFIGOPTS_CLKDIV_BM         ((uint32_t)0x0000FFFFu)  // Core clock divider, T(sck)=2*(CLKDIV+1)*T(core) bit mask
#define QSPI_CONFIGOPTS_CLKDIV_OFF        ((uint32_t)0x00000000u)  // Core clock divider offset

// CSID (0x1C) reset 0x00000000
#define QSPI_CSID_CSID_BM                 ((uint32_t)0xFFFFFFFFu)  // Chip select ID for the next command bit mask
#define QSPI_CSID_CSID_OFF                ((uint32_t)0x00000000u)  // Chip select ID for the next command offset

// COMMAND (0x20) reset 0x00000000
#define QSPI_COMMAND_LEN_BM               ((uint32_t)0x01FFFFE0u)  // Segment length minus one bit mask
#define QSPI_COMMAND_LEN_OFF              ((uint32_t)0x00000005u)  // Segment length minus one offset
#define QSPI_COMMAND_DIRECTION_BM         ((uint32_t)0x00000018u)  // Segment direction bit mask
#define QSPI_COMMAND_DIRECTION_OFF        ((uint32_t)0x00000003u)  // Segment direction offset
#define QSPI_COMMAND_DIRECTION_DUMMY      ((uint32_t)0x00000000u)  // Dummy cycles, no TX/RX
#define QSPI_COMMAND_DIRECTION_RX         ((uint32_t)0x00000008u)  // RX only
#define QSPI_COMMAND_DIRECTION_TX         ((uint32_t)0x00000010u)  // TX only
#define QSPI_COMMAND_DIRECTION_BIDIR      ((uint32_t)0x00000018u)  // Bidirectional, standard speed only
#define QSPI_COMMAND_SPEED_BM             ((uint32_t)0x00000006u)  // Segment speed bit mask
#define QSPI_COMMAND_SPEED_OFF            ((uint32_t)0x00000001u)  // Segment speed offset
#define QSPI_COMMAND_SPEED_STANDARD       ((uint32_t)0x00000000u)  // Standard SPI, one data line
#define QSPI_COMMAND_SPEED_DUAL           ((uint32_t)0x00000002u)  // Dual SPI, two data lines
#define QSPI_COMMAND_SPEED_QUAD           ((uint32_t)0x00000004u)  // Quad SPI, four data lines
#define QSPI_COMMAND_CSAAT_BM             ((uint32_t)0x00000001u)  // Chip select active after transaction bit mask
#define QSPI_COMMAND_CSAAT_OFF            ((uint32_t)0x00000000u)  // Chip select active after transaction offset

// ERROR_ENABLE (0x2C) reset 0x0000001F
#define QSPI_ERROR_ENABLE_CSIDINVAL_BM    ((uint32_t)0x00000010u)  // Enable CSID out of range error bit mask
#define QSPI_ERROR_ENABLE_CSIDINVAL_OFF   ((uint32_t)0x00000004u)  // Enable CSID out of range error offset
#define QSPI_ERROR_ENABLE_CMDINVAL_BM     ((uint32_t)0x00000008u)  // Enable invalid command segment error bit mask
#define QSPI_ERROR_ENABLE_CMDINVAL_OFF    ((uint32_t)0x00000003u)  // Enable invalid command segment error offset
#define QSPI_ERROR_ENABLE_UNDERFLOW_BM    ((uint32_t)0x00000004u)  // Enable RX FIFO underflow error bit mask
#define QSPI_ERROR_ENABLE_UNDERFLOW_OFF   ((uint32_t)0x00000002u)  // Enable RX FIFO underflow error offset
#define QSPI_ERROR_ENABLE_OVERFLOW_BM     ((uint32_t)0x00000002u)  // Enable TX FIFO overflow error bit mask
#define QSPI_ERROR_ENABLE_OVERFLOW_OFF    ((uint32_t)0x00000001u)  // Enable TX FIFO overflow error offset
#define QSPI_ERROR_ENABLE_CMDBUSY_BM      ((uint32_t)0x00000001u)  // Enable command-while-busy error bit mask
#define QSPI_ERROR_ENABLE_CMDBUSY_OFF     ((uint32_t)0x00000000u)  // Enable command-while-busy error offset

// ERROR_STATUS (0x30) reset 0x00000000, all fields rw1c
#define QSPI_ERROR_STATUS_ACCESSINVAL_BM  ((uint32_t)0x00000020u)  // Zero-byte write to TXDATA bit mask
#define QSPI_ERROR_STATUS_ACCESSINVAL_OFF ((uint32_t)0x00000005u)  // Zero-byte write to TXDATA offset
#define QSPI_ERROR_STATUS_CSIDINVAL_BM    ((uint32_t)0x00000010u)  // Command issued with CSID out of range bit mask
#define QSPI_ERROR_STATUS_CSIDINVAL_OFF   ((uint32_t)0x00000004u)  // Command issued with CSID out of range offset
#define QSPI_ERROR_STATUS_CMDINVAL_BM     ((uint32_t)0x00000008u)  // Invalid SPEED, or bidir at dual/quad bit mask
#define QSPI_ERROR_STATUS_CMDINVAL_OFF    ((uint32_t)0x00000003u)  // Invalid SPEED, or bidir at dual/quad offset
#define QSPI_ERROR_STATUS_UNDERFLOW_BM    ((uint32_t)0x00000004u)  // Read from RXDATA while RX FIFO empty bit mask
#define QSPI_ERROR_STATUS_UNDERFLOW_OFF   ((uint32_t)0x00000002u)  // Read from RXDATA while RX FIFO empty offset
#define QSPI_ERROR_STATUS_OVERFLOW_BM     ((uint32_t)0x00000002u)  // TX FIFO overflowed bit mask
#define QSPI_ERROR_STATUS_OVERFLOW_OFF    ((uint32_t)0x00000001u)  // TX FIFO overflowed offset
#define QSPI_ERROR_STATUS_CMDBUSY_BM      ((uint32_t)0x00000001u)  // Write to COMMAND while STATUS.READY=0 bit mask
#define QSPI_ERROR_STATUS_CMDBUSY_OFF     ((uint32_t)0x00000000u)  // Write to COMMAND while STATUS.READY=0 offset

// EVENT_ENABLE (0x34) reset 0x00000000
#define QSPI_EVENT_ENABLE_IDLE_BM         ((uint32_t)0x00000020u)  // Event on STATUS.ACTIVE falling bit mask
#define QSPI_EVENT_ENABLE_IDLE_OFF        ((uint32_t)0x00000005u)  // Event on STATUS.ACTIVE falling offset
#define QSPI_EVENT_ENABLE_READY_BM        ((uint32_t)0x00000010u)  // Event on STATUS.READY rising bit mask
#define QSPI_EVENT_ENABLE_READY_OFF       ((uint32_t)0x00000004u)  // Event on STATUS.READY rising offset
#define QSPI_EVENT_ENABLE_TXWM_BM         ((uint32_t)0x00000008u)  // Event on TX FIFO below watermark bit mask
#define QSPI_EVENT_ENABLE_TXWM_OFF        ((uint32_t)0x00000003u)  // Event on TX FIFO below watermark offset
#define QSPI_EVENT_ENABLE_RXWM_BM         ((uint32_t)0x00000004u)  // Event on RX FIFO above watermark bit mask
#define QSPI_EVENT_ENABLE_RXWM_OFF        ((uint32_t)0x00000002u)  // Event on RX FIFO above watermark offset
#define QSPI_EVENT_ENABLE_TXEMPTY_BM      ((uint32_t)0x00000002u)  // Event on STATUS.TXEMPTY rising bit mask
#define QSPI_EVENT_ENABLE_TXEMPTY_OFF     ((uint32_t)0x00000001u)  // Event on STATUS.TXEMPTY rising offset
#define QSPI_EVENT_ENABLE_RXFULL_BM       ((uint32_t)0x00000001u)  // Event on STATUS.RXFULL rising bit mask
#define QSPI_EVENT_ENABLE_RXFULL_OFF      ((uint32_t)0x00000000u)  // Event on STATUS.RXFULL rising offset

// Bit definitions for GPIO
//
// Field layout follows OpenTitan spi_host:
// https://opentitan.org/book/hw/ip/gpio/doc/registers.html

// ALERT_TEST (0x0C) reset 0x00000000
#define GPIO_ALERT_TEST_FATAL_FAULT_BM    ((uint32_t)0x00000001u)  // Fatal fault alert test bit mask
#define GPIO_ALERT_TEST_FATAL_FAULT_OFF   ((uint32_t)0x00000000u)  // Fatal fault alert test offset

// HW_STRAPS_DATA_IN_VALID (0x40) reset 0x00000000
#define GPIO_HW_STRAPS_DATA_IN_VALID_BM   ((uint32_t)0x00000001u)  // HW_STRAPS_DATA_IN is valid bit mask
#define GPIO_HW_STRAPS_DATA_IN_VALID_OFF  ((uint32_t)0x00000000u)  // HW_STRAPS_DATA_IN is valid offset

// Peripheral register bits definition

/////////////////////
// Exported macros //
/////////////////////

#define SET_BIT(REG, BIT)         ((REG) |= (BIT))

#define CLEAR_BIT(REG, BIT)       ((REG) &= ~(BIT))

#define READ_BIT(REG, BIT)        ((REG) & (BIT))

#define READ_FIELD(REG, BM, OFF)  (((REG) & (BM)) >> (OFF))

#define CLEAR_REG(REG)            ((REG) = (0x0))

#define WRITE_REG(REG, VAL)       ((REG) = (VAL))

#define READ_REG(REG)             ((REG))

#define MODIFY_REG(REG, CLEARMASK, SETMASK)  ((REG) = (((REG) & (~(CLEARMASK))) | (SETMASK)))

// Exported macros

#ifdef __cplusplus
}
#endif  // __cplusplus

#endif  // __VERNII_H

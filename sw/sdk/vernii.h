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
#define OCM_BASE    ((uint32_t)0x0000_0000u)  // On-chip memory
#define ACLINT_BASE ((uint32_t)0x0200_0000u)  // Advanced Core Local Interruptor
#define PERIPH_BASE ((uint32_t)0x0300_0000u)  // Peripherals
#define PLIC_BASE   ((uint32_t)0x0C00_0000u)  // Platform-Level Interrupt Controller
#define EXT_BASE    ((uint32_t)0x8000_0000u)  // External address space

// Peripheral offsets from PERIPH_BASE
#define SCB_OFFSET   ((uint32_t)0x0000_0000u)  // System Control Block
#define UART0_OFFSET ((uint32_t)0x0001_0000u)  // UART0
#define QSPI0_OFFSET ((uint32_t)0x0002_0000u)  // QSPI0
#define GPIOA_OFFSET ((uint32_t)0x0003_0000u)  // GPIO Port A
#define ZSBL_OFFSET  ((uint32_t)0x0004_0000u)  // Zero-Stage Boot Loader
#define DM_OFFSET    ((uint32_t)0x0005_0000u)  // Debug Module

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
    uint32_t      RESERVED1[1022];  // 0xC008 - 0xFFFF Reserved
    __O  uint32_t SETSSIP[4095];    // 0x10000 + 4*hartidx SETSSIP Set supervisor-mode software interrupt pending
} ACLINT_TypeDef;

// System Control Block

typedef struct {  // SCB_TypeDef
    __IO uint32_t SCRATCH0;     // 0x00 SCB Scratch register 0
    __I  uint32_t BOOTSEL;      // 0x04 SCB Boot select register
    uint32_t      RESERVED[1];  // 0x08 - 0x00C Reserved
    __IO uint32_t LLCSEL;       // 0x00C SCB Last-level cache way select
    __IO uint32_t LLCCRPSEL;    // 0x010 SCB LLC replacement policy select
    __IO uint32_t LLCINV;       // 0x014 SCB LLC invalidateji
    reg64_t       LLCRDACC;     // 0x018 SCB LLC read access count
    reg64_t       LLCRDMISS;    // 0x020 SCB LLC read miss count
    reg64_t       LLCRDWRACC;   // 0x028 SCB LLC write access count
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
    __IO uint32_t CTRL;          // 0x10 RW Control register
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

// TODO

// Bit definitions for UART

// TODO

// Bit definitions for QSPI

// TODO

// Bit definitions for GPIO

// TODO

// Peripheral register bits definition

/////////////////////
// Exported macros //
/////////////////////

#define SET_BIT(REG, BIT)     ((REG) |= (BIT))

#define CLEAR_BIT(REG, BIT)   ((REG) &= ~(BIT))

#define READ_BIT(REG, BIT)    ((REG) & (BIT))

#define CLEAR_REG(REG)        ((REG) = (0x0))

#define WRITE_REG(REG, VAL)   ((REG) = (VAL))

#define READ_REG(REG)         ((REG))

#define MODIFY_REG(REG, CLEARMASK, SETMASK)  ((REG) = (((REG) & (~(CLEARMASK))) | (SETMASK)))

// Exported macros

#ifdef __cplusplus
}
#endif  // __cplusplus

#endif  // __VERNII_H

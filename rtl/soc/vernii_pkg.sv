// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
//
// Emil Popović <mail@emilpopovic.me>

`include "axi/typedef.svh"
`include "register_interface/typedef.svh"
`include "apb/typedef.svh"

package vernii_pkg;

//////////////
// Typedefs //
//////////////

localparam int unsigned AddrWidth    = 32;
localparam int unsigned DataWidth    = 32;
localparam int unsigned StrbWidth    = DataWidth / 8;
localparam int unsigned AxiIdWidth   = 1;
localparam int unsigned AxiUserWidth = 1;

typedef logic [AddrWidth-1:0]    addr_t;
typedef logic [DataWidth-1:0]    data_t;
typedef logic [StrbWidth-1:0]    strb_t;
typedef logic [AxiIdWidth-1:0]   id_t;
typedef logic [AxiUserWidth-1:0] user_t;

`AXI_LITE_TYPEDEF_ALL(vernii_axi_lite, addr_t, data_t, strb_t)
`AXI_TYPEDEF_ALL(vernii_axi, addr_t, id_t, data_t, strb_t, user_t)
`REG_BUS_TYPEDEF_ALL(vernii_reg, addr_t, data_t, strb_t)
`APB_TYPEDEF_ALL(vernii_apb, addr_t, data_t, strb_t)

///////////////////////////
// System identification //
///////////////////////////

// SCB.SYSID, magic value for compatible system family that tells id block is valid
localparam logic [31:0] SysIdMagic = 32'h5645_524E;  // "VERN"

// SCB.SYSIMPL.SYSTEM, names the system itself. Increment for later versions of systems
// with software compatibility with Vernii (i.e. have the same SYSID).
localparam logic [15:0] SysIdVernii = 16'h0001;

// SCB.SYSVER, names the version
// SCB.SYSVER.RELEASE says whether it is the release commit, or a compatible modified version
localparam logic [7:0] SysVerMajor   = 8'd0;
localparam logic [7:0] SysVerMinor   = 8'd3;
localparam logic [7:0] SysVerPatch   = 8'd0;
localparam bit         SysVerRelease = 1'b0;

// SYSCFG block, describes the configuration of the system
// Allows software to autodetect the system configuration
typedef struct packed {
    // SYSIMPL, System Implementation Register
    logic [15:0] variant;             // Integrator-assigned, 0 is the reference config

    // SYSFEAT, System Feature Register
    logic        ocm;                 // On-chip memory present
    logic        llc;                 // LLC present
    logic        sram_tags;           // LLC tags in SRAM (not flops)
    logic        mmu;                 // MMU present
    logic        fine_tlb_flush;      // sfence.vma with rs1 flushes one entry
    logic        pmp;                 // PMP enforced
    logic        ptw_pmp;             // PMP enforced on page table walks
    logic        isa_e;               // RV32E register file
    logic        isa_m;               // M extension
    logic        isa_a;               // A extension
    logic        fast_mul;            // Single-cycle multiplier
    logic        zsbl_rom;            // Use built-in boot ROM
    logic        s_axi_gp;            // General-purpose AXI Lite subordinate port present
    logic        halt_on_end;         // Core halts on the end marker (for simulation)

    // SYSCACHECFG, System Cache Configuration Register
    logic [15:0] line_bytes;          // Bytes in LLC line
    logic [7:0]  ways;                // OCM/LLC ways

    // SYSMMUCFG, System MMU Configuration Register
    logic [7:0]  itlb_entries;
    logic [7:0]  dtlb_entries;
    logic [7:0]  pmp_entries;

    // SYSIRQCFG, System Interrupt Configuration Register
    logic [7:0]  num_ext_irq;         // External lines wired to the PLIC
    logic [7:0]  num_gpio_a_irq;      // GPIO port A lines wired to the PLIC

    // SYSBUSCFG, System Bus Configuration Register
    logic [7:0]  num_m_reg_rules;     // Populated manager register bus rules
    logic [7:0]  num_s_axi_gp_rules;  // Populated GP subordinate rules

    // SYSBOOTCFG, System Boot Configuration Register
    logic [15:0] zsbl_rom_words;      // Words of boot ROM image
    logic [7:0]  boot_sel_w;          // Boot select pads

    // SYSOCMBASE..SYSCACHEDSIZE, System Address Map Registers
    logic [31:0] ocm_base;
    logic [31:0] ocm_size;
    logic [31:0] ext_base;
    logic [31:0] ext_size;
    logic [31:0] cached_base;
    logic [31:0] cached_size;
} vernii_syscfg_t;

localparam int unsigned NumIntRegPorts = 9;

endpackage

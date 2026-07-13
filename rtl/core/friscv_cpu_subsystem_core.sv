// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the top-level FRISC-V CPU subsystem, connecting the core to external interfaces.
 * It only provides the external memory interface and interrupt inputs.
 *
 * Use this module when instantiating the CPU subsystem in a larger SoC, together with an accompanying adapter.
 * See: friscv_cpu_subsystem_axi.sv for an example of using this core with an AXI4 external bus.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_cpu_subsystem_core #(
    parameter int unsigned RAM_BASE           = 32'h8000_0000,
    parameter int unsigned ZSBL_ROM_SIZE_BYTES = 0,
    parameter int unsigned ZSBL_BASE           = 32'h20000,
    parameter int unsigned DM_BASE             = 32'h0000_0000,
    parameter int unsigned DM_HALT_OFFSET      = 32'h800,
    parameter int unsigned DM_EXC_OFFSET       = 32'h810,

    // If enabled, buffer outbound requests to improve timing
    parameter logic ENABLE_L2_BUFFER = 0,

    // Memory protection and address translation
    parameter logic ENABLE_MMU      = 1,
    parameter logic ENFORCE_PMP     = 0,
    parameter logic ENFORCE_PTW_PMP = 0,
    parameter int   PMP_ENTRIES     = 64,
    parameter int   PMP_USABLE      = 64,
    // Must be a power of 2 greater than 1
    parameter int   ITLB_ENTRIES = 2,
    parameter int   DTLB_ENTRIES = 4,
    // If not enabled, any sfence.vma will flush all TLB entries
    parameter logic ENABLE_FINE_TLB_FLUSH = 0,

    // Extension selection
    parameter logic ENABLE_MUL = 1,
    parameter logic ENABLE_DIV = 1,
    // Use a single-cycle combinational multiplier instead of the iterative multiplier
    parameter logic ENABLE_FAST_MUL = 0,
    parameter logic ENABLE_EXTENSION_A = 1,

    // If enabled, a write to END_ADDRESS will stall the core until reset
    parameter logic ENABLE_HALT_ON_END_ADDRESS = 1,
    // If enabled, entering an EBREAK instruction will halt the core until reset
    parameter logic ENABLE_HALT_ON_ENTER_EBREAK = 0,
    // If enabled, the first MRET or SRET after entering an EBREAK handler will halt the core until reset
    parameter logic ENABLE_HALT_ON_RET_FROM_EBREAK = 0,

    // Calculated parameters, do not change
    parameter int unsigned RESET_VEC = (ZSBL_ROM_SIZE_BYTES > 0) ? ZSBL_BASE : RAM_BASE
) (
    input  logic         i_clk,
    input  logic         i_rstn,
    output logic         o_end,

    input  logic         i_msip,
    input  logic         i_mtip,
    input  logic         i_meip,
    input  logic         i_seip,

    input  mtime_t       i_mtime,

    friscv_mem_if.master mem_if,

    input  logic         i_dbg_req
);

mem_width_e w_size;
addr_t      w_addr;
data_t      w_wdata;
data_t      w_rdata;
rw_cmd_e    w_rw;
logic       w_wait;
logic       w_burst_en;
logic       w_beat_valid;

logic w_mem_err;
assign w_mem_err = mem_if.err;

// ============================================================
// Core complex instance
// ============================================================

friscv_core_complex #(
    .HART_ID             ( 0                   ),
    .RESET_VEC           ( RESET_VEC           ),
    .ZSBL_ROM_SIZE_BYTES ( ZSBL_ROM_SIZE_BYTES ),
    .DM_BASE             ( DM_BASE             ),
    .DM_HALT_OFFSET      ( DM_HALT_OFFSET      ),
    .DM_EXC_OFFSET       ( DM_EXC_OFFSET       ),

    .ENABLE_L2_BUFFER               ( ENABLE_L2_BUFFER               ),
    .ENABLE_MMU                     ( ENABLE_MMU                     ),
    .ENFORCE_PMP                    ( ENFORCE_PMP                    ),
    .ENFORCE_PTW_PMP                ( ENFORCE_PTW_PMP                ),
    .PMP_ENTRIES                    ( PMP_ENTRIES                    ),
    .PMP_USABLE                     ( PMP_USABLE                     ),
    .ITLB_ENTRIES                   ( ITLB_ENTRIES                   ),
    .DTLB_ENTRIES                   ( DTLB_ENTRIES                   ),
    .ENABLE_FINE_TLB_FLUSH          ( ENABLE_FINE_TLB_FLUSH          ),
    .ENABLE_MUL                     ( ENABLE_MUL                     ),
    .ENABLE_DIV                     ( ENABLE_DIV                     ),
    .ENABLE_FAST_MUL                ( ENABLE_FAST_MUL                ),
    .ENABLE_EXTENSION_A             ( ENABLE_EXTENSION_A             ),
    .ENABLE_HALT_ON_END_ADDRESS     ( ENABLE_HALT_ON_END_ADDRESS     ),
    .ENABLE_HALT_ON_ENTER_EBREAK    ( ENABLE_HALT_ON_ENTER_EBREAK    ),
    .ENABLE_HALT_ON_RET_FROM_EBREAK ( ENABLE_HALT_ON_RET_FROM_EBREAK )
) cc_0 (
    .i_clk        ( i_clk        ),
    .i_rstn       ( i_rstn       ),
    .o_end        ( o_end        ),
    .i_msip       ( i_msip       ),
    .i_mtip       ( i_mtip       ),
    .i_meip       ( i_meip       ),
    .i_seip       ( i_seip       ),
    .i_mtime      ( i_mtime      ),
    .o_mem_size   ( w_size       ),
    .o_mem_addr   ( w_addr       ),
    .o_mem_wdata  ( w_wdata      ),
    .i_mem_rdata  ( w_rdata      ),
    .o_mem_rw     ( w_rw         ),
    .i_mem_wait   ( w_wait       ),
    .i_mem_err    ( w_mem_err    ),
    .o_burst_en   ( w_burst_en   ),
    .i_beat_valid ( w_beat_valid ),
    .i_dbg_req    ( i_dbg_req    )
);

// ============================================================
// Connect external memory interface
// ============================================================

assign mem_if.size     = w_size;
assign mem_if.addr     = w_addr;
assign mem_if.wdata    = w_wdata;
assign mem_if.rw       = w_rw;
assign mem_if.burst_en = w_burst_en;

assign w_rdata         = mem_if.rdata;
assign w_wait          = mem_if.wait_req;
assign w_beat_valid    = mem_if.beat_valid;

endmodule

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

module friscv_cpu_subsystem_core import friscv_pkg::*, friscv_mem_pkg::*; #(
    parameter int unsigned RamBase          = 32'h8000_0000,
    parameter bit          ZsblRomEnable    = 1'b0,
    parameter int unsigned ZsblRomWords     = 1,
    parameter logic [31:0] ZsblRomProg [ZsblRomWords] = '{default: '0},
    parameter int unsigned ZsblRomBase      = 32'h0020_0000,
    parameter int unsigned DmBase           = 32'h0000_0000,
    parameter int unsigned DmHaltOffset     = 32'h800,
    parameter int unsigned DmExcOffset      = 32'h810,

    // Memory protection and address translation
    parameter logic EnableMmu      = 1,
    parameter logic EnforcePmp     = 0,
    parameter logic EnforcePtwPmp  = 0,
    parameter int   PmpEntries     = 8,
    parameter int   PmpUsable      = 8,
    // Must be a power of 2 greater than 1
    parameter int   ItlbEntries = 2,
    parameter int   DtlbEntries = 4,
    // If not enabled, any sfence.vma will flush all TLB entries
    parameter logic EnableFineTlbFlush = 0,

    // Extension selection
    parameter logic EnableMul = 1,
    parameter logic EnableDiv = 1,
    // Use a single-cycle combinational multiplier instead of the iterative multiplier
    parameter logic EnableFastMul = 0,
    parameter logic EnableExtensionA = 1,

    // If enabled, a write to END_ADDRESS will stall the core until reset
    parameter logic HaltOnEndAddress    = 0,
    // If enabled, entering an EBREAK instruction will halt the core until reset
    parameter logic HaltOnEnterEbreak   = 0,
    // If enabled, the first MRET or SRET after entering an EBREAK handler will halt the core until reset
    parameter logic HaltOnRetFromEbreak = 0
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

localparam int unsigned ResetVec = ZsblRomEnable ? ZsblRomBase : RamBase;

// Elaboration-time parameter checks
if (!EnableMul && EnableFastMul) begin : gen_chk_fast_mul_has_mul
    $fatal(1, "EnableFastMul enabled, but EnableMul disabled. Fast multiplier requires MUL.");
end
if (!EnableMmu && EnforcePmp) begin : gen_chk_pmp_requires_mmu
    $fatal(1, "EnforcePmp enabled, but EnableMmu disabled. PMP enforcement requires MMU.");
end
if (!EnforcePmp && EnforcePtwPmp) begin : gen_chk_ptw_pmp_requires_pmp
    $fatal(1, "EnforcePtwPmp enabled, but EnforcePmp disabled. PTW PMP enforcement requires PMP enforcement.");
end
if (PmpUsable > PmpEntries) begin : gen_chk_pmp_usable_le_entries
    $fatal(1, "PmpUsable (%0d) exceeds PmpEntries (%0d).", PmpUsable, PmpEntries);
end
if (PmpEntries > 64) begin : gen_chk_pmp_entries_le_64
    $fatal(1, "PmpEntries (%0d) exceeds the maximum of 64.", PmpEntries);
end

mem_width_e w_size;
addr_t      w_addr;
data_t      w_wdata;
data_t      w_rdata;
rw_cmd_e    w_rw;
logic       w_wait;
logic       w_burst_en;

logic w_mem_err;
assign w_mem_err = mem_if.err;

// ============================================================
// Core complex instance
// ============================================================

friscv_core_complex #(
    .HartId              ( 0                   ),
    .ResetVec            ( ResetVec            ),
    .ZsblRomEnable       ( ZsblRomEnable       ),
    .ZsblRomWords        ( ZsblRomWords        ),
    .ZsblRomProg         ( ZsblRomProg         ),
    .DmBase              ( DmBase              ),
    .DmHaltOffset        ( DmHaltOffset        ),
    .DmExcOffset         ( DmExcOffset         ),
    .EnableMmu           ( EnableMmu           ),
    .EnforcePmp          ( EnforcePmp          ),
    .EnforcePtwPmp       ( EnforcePtwPmp       ),
    .PmpEntries          ( PmpEntries          ),
    .PmpUsable           ( PmpUsable           ),
    .ItlbEntries         ( ItlbEntries         ),
    .DtlbEntries         ( DtlbEntries         ),
    .EnableFineTlbFlush  ( EnableFineTlbFlush  ),
    .EnableMul           ( EnableMul           ),
    .EnableDiv           ( EnableDiv           ),
    .EnableFastMul       ( EnableFastMul       ),
    .EnableExtensionA    ( EnableExtensionA    ),
    .HaltOnEndAddress    ( HaltOnEndAddress    ),
    .HaltOnEnterEbreak   ( HaltOnEnterEbreak   ),
    .HaltOnRetFromEbreak ( HaltOnRetFromEbreak )
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

endmodule

// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
//
// Version info is listed in friscv_pkg.sv

/*
 * This module implements the top-level FRISC-V CPU subsystem, connecting the core to external interfaces.
 * It only provides the external memory interface and interrupt inputs.
 *
 * Use this module when instantiating the CPU subsystem in a larger SoC, together with an accompanying adapter.
 * See: friscv_cpu_subsystem_axi.sv for an example of using this core with an AXI4 external bus.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_cpu_subsystem_core (
    input  logic         i_clk,
    input  logic         i_rstn,
    output logic         o_end,

    input  logic         i_msip,
    input  logic         i_mtip,
    input  logic         i_meip,

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
    .HART_ID(0)
) cc_0 (
    .i_clk        ( i_clk        ),
    .i_rstn       ( i_rstn       ),
    .o_end        ( o_end        ),
    .i_msip       ( i_msip       ),
    .i_mtip       ( i_mtip       ),
    .i_meip       ( i_meip       ),
    .i_mtime      ( i_mtime      ),
    .o_mem_size   ( w_size       ),
    .o_mem_addr   ( w_addr       ),
    .o_mem_wdata  ( w_wdata      ),
    .i_mem_rdata  ( w_rdata      ),
    .o_mem_rw     ( w_rw         ),
    .i_mem_wait   ( w_wait       ),
    .i_mem_err    ( w_mem_err    ),
    .o_burst_en   ( w_burst_en   ),
    .i_beat_valid ( w_beat_valid )
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

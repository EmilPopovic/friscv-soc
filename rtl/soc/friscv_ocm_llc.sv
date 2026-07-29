// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

`timescale 1ns/1ps

import friscv_pkg::*;

module friscv_ocm_llc #(
    parameter  int unsigned REGION_LOG2 = 25,  // 32MB
    parameter  int unsigned LINE_BYTES  = 64,
    parameter  int unsigned WAYS        = 4,
    parameter  int unsigned SIZE_BYTES  = 16*1024,
    localparam int unsigned SETS        = SIZE_BYTES / (LINE_BYTES * WAYS),
    localparam int unsigned OFFSET_W    = $clog2(LINE_BYTES),
    localparam int unsigned IDX_W       = $clog2(SETS),
    localparam int unsigned TAG_W       = REGION_LOG2 - OFFSET_W - IDX_W
) (
    input  logic            i_clk,
    input  logic            i_rstn,
    input  logic            i_mode_valid,
    input  logic [WAYS-1:0] i_mode_cache_en,

    friscv_mem_if.slave     s_mem_if,  // To CPU
    friscv_mem_if.master    m_mem_if   // To Memory
);

// ============================================================
// Convert to memory interface
// ============================================================

logic        w_req, w_gnt, w_we, w_rvalid;
logic [31:0] w_addr, w_wdata, w_rdata;
logic [3:0]  w_be;

friscv_to_mem #(
    .REGISTER_REQ (0)
) to_mem (
    .i_clk       ( i_clk    ),
    .i_rstn      ( i_rstn   ),
    .req_o       ( w_req    ),
    .addr_o      ( w_addr   ),
    .we_o        ( w_we     ),
    .wdata_o     ( w_wdata  ),
    .be_o        ( w_be     ),
    .gnt_i       ( w_gnt    ),
    .rvalid_i    ( w_rvalid ),
    .err_i       ( 1'b0     ),
    .other_err_i ( 1'b0     ),
    .rdata_i     ( w_rdata  ),
    .mem_if      ( s_mem_if )
);

assign w_gnt = 1'b1;  // SRAM always ready
always_ff @(posedge i_clk) begin
    if (!i_rstn) w_rvalid <= 1'b0;
    else         w_rvalid <= w_req;
end

// ============================================================
// SRAM blocks
// ============================================================

localparam int unsigned WAY_WORDS = SIZE_BYTES / WAYS / 4;

logic [WAYS-1:0] r_way_is_cache;

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_way_is_cache <= '0;
    end else if (i_mode_valid) begin
        r_way_is_cache <= i_mode_cache_en;
    end
end

logic [WAYS-1:0]       w_way_req, w_way_we;
logic [WAYS-1:0][31:0] w_way_wdata, w_way_rdata;
logic [WAYS-1:0][3:0]  w_way_be;
logic [WAYS-1:0][$clog2(WAY_WORDS)-1:0] w_way_addr;

for (genvar i = 0; i < WAYS; i++) begin : gen_ways
    tc_sram #(
        .NumWords ( WAY_WORDS ),
        .DataWidth( 32        ),
        .ByteWidth( 8         ),
        .NumPorts ( 1         ),
        .Latency  ( 1         )
    ) way_sram (
        .clk_i   ( i_clk          ),
        .rst_ni  ( i_rstn         ),
        .req_i   ( w_way_req  [i] ),
        .we_i    ( w_way_we   [i] ),
        .addr_i  ( w_way_addr [i] ),
        .wdata_i ( w_way_wdata[i] ),
        .be_i    ( w_way_be   [i] ),
        .rdata_o ( w_way_rdata[i] )
    );
end

assign m_mem_if.rw = RW_IDLE;  // TODO temporary tieoff

// ============================================================
// SRAM inputs
// ============================================================

logic [$clog2(WAY_WORDS)-1:0] w_ocm_addr, w_llc_addr;
logic [$clog2(WAYS)-1:0] w_ocm_way_sel, w_llc_way_sel;

// Full OCM address is [X, WAY_ADDR, WAY_SEL, BYTE_SEL], where BYTE_SEL is 2 bits for 32-bit address
assign w_ocm_addr    = w_addr[$clog2(WAY_WORDS)+1:2];
assign w_ocm_way_sel = w_addr[$clog2(WAY_WORDS)+$clog2(WAYS)+1:$clog2(WAY_WORDS)+2];

always_comb begin
    for (int unsigned i = 0; i < WAYS; i++) begin
        if (r_way_is_cache[i]) begin
            w_way_req  [i] = 1'b0;
            w_way_addr [i] = '0;
            w_way_we   [i] = 1'b0;
            w_way_wdata[i] = '0;
            w_way_be   [i] = '0;
        end else if (w_ocm_way_sel == i) begin
            w_way_req  [i] = 1'b1;
            w_way_addr [i] = w_ocm_addr;
            w_way_we   [i] = w_we;
            w_way_wdata[i] = w_wdata;
            w_way_be   [i] = w_be;
        end else begin
            w_way_req  [i] = 1'b0;
            w_way_addr [i] = '0;
            w_way_we   [i] = 1'b0;
            w_way_wdata[i] = '0;
            w_way_be   [i] = '0;
        end
    end
end

// ============================================================
// SRAM outputs
// ============================================================

always_comb begin
    w_rdata = '0;
    for (int unsigned i = 0; i < WAYS; i++) begin
        if (r_way_is_cache[i]) begin
            // Do nothing, this way is not used
        end else if (w_ocm_way_sel == i) begin
            w_rdata = w_way_rdata[i];
        end
    end
end

endmodule

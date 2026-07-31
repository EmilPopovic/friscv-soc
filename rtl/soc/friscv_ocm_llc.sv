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
    parameter  int unsigned OCM_BASE    = 32'h0000_0000,
    parameter  int unsigned REGION_BASE = 32'h8000_0000,
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
    input  logic [WAYS-1:0] i_way_is_cache,  // 1 = this way is cache, 0 = this way is OCM
    input  logic            i_crpsel,        // 0 = round-robin, 1 = random

    friscv_mem_if.slave     s_mem_if,  // From the hub: OCM region and cacheable region
    friscv_mem_if.master    m_mem_if   // To external memory
);

// ============================================================
// Convert to memory interface
// ============================================================

logic        w_req, w_gnt, w_we, w_rvalid, w_err;
logic [31:0] w_addr, w_wdata, w_rdata;
logic [3:0]  w_be;

// An access to the OCM region is illegal if the selected way is configured as cache
logic w_illegal_ocm_access;

friscv_to_mem #(
    .REGISTER_REQ ( 1 )
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
    .err_i       ( w_err    ),
    .other_err_i ( 1'b0     ),
    .rdata_i     ( w_rdata  ),
    .mem_if      ( s_mem_if )
);

// ============================================================
// Address decode
// ============================================================

logic w_match_cached, w_match_ocm;
assign w_match_cached = (w_addr - addr_t'(REGION_BASE)) < (addr_t'(1) << REGION_LOG2);
assign w_match_ocm    = (w_addr - addr_t'(OCM_BASE)) < addr_t'(SIZE_BYTES);

// If regions overlap, OCM takes priority
logic w_sel_ocm, w_sel_cached;
assign w_sel_ocm    = w_match_ocm;
assign w_sel_cached = w_match_cached && !w_sel_ocm;

// Everything that is not OCM is served downstream
logic w_fwd;
assign w_fwd = !w_sel_ocm;

// ============================================================
// Downstream path
// ============================================================

logic w_fwd_req, w_fwd_done;
assign w_fwd_req  = w_req && w_fwd;
assign w_fwd_done = w_fwd_req && !m_mem_if.wait_req;

assign m_mem_if.addr     = w_addr;
assign m_mem_if.size     = s_mem_if.size;
assign m_mem_if.wdata    = w_wdata;
assign m_mem_if.rw       = !w_fwd_req ? RW_IDLE : w_we ? RW_WRITE : RW_READ;
assign m_mem_if.burst_en = 1'b0;

// ============================================================
// Request completion
// ============================================================

assign w_gnt = w_fwd ? w_fwd_done : 1'b1;

data_t r_fwd_rdata;
logic  r_fwd_sel;

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        w_rvalid    <= 1'b0;
        w_err       <= 1'b0;
        r_fwd_sel   <= 1'b0;
        r_fwd_rdata <= '0;
    end else begin
        w_rvalid <= w_req && w_gnt;
        if (w_req && w_gnt) begin
            w_err       <= w_fwd ? m_mem_if.err : w_illegal_ocm_access;
            r_fwd_sel   <= w_fwd;
            r_fwd_rdata <= m_mem_if.rdata;
        end
    end
end

// ============================================================
// SRAM blocks
// ============================================================

localparam int unsigned WAY_WORDS = SIZE_BYTES / WAYS / 4;

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

// ============================================================
// LLC mode
// ============================================================

typedef enum logic [1:0] {
    LLC_IDLE,
    LLC_LOOKUP,
    LLC_REFILL
} llc_state_e;

logic w_cache_enabled;
assign w_cache_enabled = |i_way_is_cache;  // Cache is enabled if any way is configured as cache

logic [WAYS-1:0][SETS-1:0][TAG_W-1:0] r_tag_arr;
logic [WAYS-1:0][SETS-1:0]            r_valid_arr;

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_tag_arr   <= '0;
        r_valid_arr <= '0;
    end else begin
        // TODO implement cache replacement policy
    end
end

// Split address into tag, index, and offset
logic [OFFSET_W-1:0] w_offset;
logic [IDX_W-1:0]    w_idx;
logic [TAG_W-1:0]    w_tag;
assign {w_tag, w_idx, w_offset} = w_addr[REGION_LOG2-1:0];

// Tag lookup
logic [WAYS-1:0] w_hit_arr_d, r_hit_arr;
for (genvar i = 0; i < WAYS; i++) begin : gen_hit_arr
    assign w_hit_arr_d[i] = i_way_is_cache[i] && r_valid_arr[i][w_idx] && (r_tag_arr[i][w_idx] == w_tag);
end

// Cache hit if any way matches
logic w_hit;
assign w_hit = |r_hit_arr;

always_ff @(posedge i_clk) begin
    if (!i_rstn) r_hit_arr <= '0;
    else         r_hit_arr <= w_hit_arr_d;
end

// Line selection
logic [$clog2(WAY_WORDS)-1:0] w_lookup_addr;
assign w_lookup_addr = {w_idx, w_offset[OFFSET_W-1:2]};  // 32-bit word address within line

// This cycle is a tag lookup
logic w_do_lookup;
assign w_do_lookup = w_sel_cached && w_cache_enabled && w_req && !w_we;

// Hit/miss is ready this cycle
logic r_was_lookup;
always_ff @(posedge i_clk) begin
    if (!i_rstn) r_was_lookup <= 1'b0;
    else         r_was_lookup <= w_do_lookup;
end

// ============================================================
// SRAM read/write
// ============================================================

logic [$clog2(WAY_WORDS)-1:0] w_ocm_addr;
logic [$clog2(WAYS)-1:0]      w_ocm_way_sel;

// Full OCM address is [X, WAY_SEL, WAY_ADDR, BYTE_SEL], where BYTE_SEL is 2 bits for 32-bit address
assign w_ocm_addr    = w_addr[$clog2(WAY_WORDS)+1:2];
assign w_ocm_way_sel = w_addr[$clog2(WAY_WORDS)+$clog2(WAYS)+1:$clog2(WAY_WORDS)+2];

assign w_illegal_ocm_access = w_sel_ocm && i_way_is_cache[w_ocm_way_sel];

always_comb begin
    for (int unsigned i = 0; i < WAYS; i++) begin
        w_way_req  [i] = 1'b0;
        w_way_addr [i] = '0;
        w_way_we   [i] = 1'b0;
        w_way_wdata[i] = '0;
        w_way_be   [i] = '0;

        if (i_way_is_cache[i]) begin
            // TODO implement cache mode
            if (w_req && w_do_lookup && !r_was_lookup && !w_we) begin
                // Read cache lines in parallel with tag lookup for a read
                w_way_req  [i] = 1'b1;
                w_way_addr [i] = w_lookup_addr;
                w_way_we   [i] = 1'b0;
                w_way_wdata[i] = '0;
                w_way_be   [i] = w_be;
            end
        end else begin
            if (w_ocm_way_sel == i && w_req && w_sel_ocm) begin
                // OCM access
                w_way_req  [i] = 1'b1;
                w_way_addr [i] = w_ocm_addr;
                w_way_we   [i] = w_we;
                w_way_wdata[i] = w_wdata;
                w_way_be   [i] = w_be;
            end
        end
    end
end

always_comb begin
    if (r_fwd_sel) begin
        w_rdata = r_fwd_rdata;
    end else begin
        w_rdata = '0;
        for (int unsigned i = 0; i < WAYS; i++) begin
            if (i_way_is_cache[i] && r_was_lookup && r_hit_arr[i]) begin
                w_rdata = w_way_rdata[i];
            end else if (w_ocm_way_sel == i && w_sel_ocm) begin
                w_rdata = w_way_rdata[i];
            end
        end
    end
end

endmodule

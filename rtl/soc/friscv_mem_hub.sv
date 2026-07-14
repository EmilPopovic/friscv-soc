// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

`timescale 1ns/1ps

import friscv_pkg::*;

module friscv_mem_hub #(
    parameter int unsigned MEM_BASE  = 32'h8000_0000,
    parameter int unsigned MEM_SIZE  = 32'h8000_0000,
    parameter int unsigned SRAM_BASE = 32'h0000_0000,
    parameter int unsigned SRAM_SIZE = 32'h0100_0000
) (
    input  logic         i_clk,
    input  logic         i_rstn,

    friscv_mem_if.slave  s_cpu_if,  // To CPU
    friscv_mem_if.slave  s_dm_if,   // To DM
    friscv_mem_if.master m_ext_if,  // To downstream
    friscv_mem_if.master m_sys_if   // To SoC
);

friscv_mem_if granted_if ();

// ============================================================
// Arbitration between CPU and DM master
// ============================================================

typedef enum logic [1:0] {
    S_IDLE,
    S_HOLD_CPU,
    S_HOLD_DM
} state_t;

state_t r_state, w_next_state;

addr_t      r_cpu_addr;
mem_width_e r_cpu_size;
data_t      r_cpu_wdata;
rw_cmd_e    r_cpu_rw;
addr_t      r_dm_addr;
mem_width_e r_dm_size;
data_t      r_dm_wdata;
rw_cmd_e    r_dm_rw;

// ============================================================
// Issue selection
// ============================================================

logic w_take_cpu, w_take_dm, w_take_any;

logic w_cpu_en, w_dm_en;
assign w_cpu_en = s_cpu_if.rw != RW_IDLE;
assign w_dm_en  = s_dm_if.rw  != RW_IDLE;

always_comb begin
    w_take_cpu = 1'b0;
    w_take_dm = 1'b0;
    if (r_state == S_IDLE) begin
        // DM has priority
        if (w_cpu_en && w_dm_en) begin
            w_take_cpu = 1'b0;
            w_take_dm  = 1'b1;
        end else begin
            w_take_cpu = w_cpu_en;
            w_take_dm  = w_dm_en;
        end
    end
end

assign w_take_any = w_take_cpu | w_take_dm;

// A transaction is on the bus this cycle if it is being issued now, or held
logic w_busy_cpu, w_busy_dm;
assign w_busy_cpu = w_take_cpu | (r_state == S_HOLD_CPU);
assign w_busy_dm  = w_take_dm  | (r_state == S_HOLD_DM);

// Must park in a HOLD state, issued this cycle but the memory did not complete
logic w_park;
assign w_park = w_take_any & granted_if.wait_req;

// ============================================================
// Next state
// ============================================================

always_comb begin
    w_next_state = r_state;
    case (r_state)
        S_IDLE:     if (w_park) w_next_state = w_take_cpu ? S_HOLD_CPU : S_HOLD_DM;
        S_HOLD_CPU,
        S_HOLD_DM:  if (!granted_if.wait_req) w_next_state = S_IDLE;
        default:    w_next_state = S_IDLE;
    endcase
end

// ============================================================
// Sequential
// ============================================================

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_state     <= S_IDLE;
        r_cpu_addr  <= '0;
        r_cpu_size  <= WIDTH_I32;
        r_cpu_wdata <= '0;
        r_cpu_rw    <= RW_IDLE;
        r_dm_addr   <= '0;
        r_dm_size   <= WIDTH_I32;
        r_dm_wdata  <= '0;
        r_dm_rw     <= RW_IDLE;
    end else begin
        r_state <= w_next_state;

        // Freeze the request if it is going to be held
        if (w_park && w_take_cpu) begin
            r_cpu_addr  <= s_cpu_if.addr;
            r_cpu_size  <= s_cpu_if.size;
            r_cpu_wdata <= s_cpu_if.wdata;
            r_cpu_rw    <= s_cpu_if.rw;
        end
        if (w_park && w_take_dm) begin
            r_dm_addr  <= s_dm_if.addr;
            r_dm_size  <= s_dm_if.size;
            r_dm_wdata <= s_dm_if.wdata;
            r_dm_rw    <= s_dm_if.rw;
        end
    end
end

// ============================================================
// Output
// ============================================================

always_comb begin
    granted_if.addr  = '0;
    granted_if.size  = WIDTH_I32;
    granted_if.wdata = '0;
    granted_if.rw    = RW_IDLE;
    s_cpu_if.wait_req = 1'b0;
    s_dm_if.wait_req  = 1'b0;
    s_cpu_if.err      = 1'b0;
    s_dm_if.err       = 1'b0;

    if (w_busy_cpu) begin
        granted_if.addr  = w_take_cpu ? s_cpu_if.addr  : r_cpu_addr;
        granted_if.size  = w_take_cpu ? s_cpu_if.size  : r_cpu_size;
        granted_if.wdata = w_take_cpu ? s_cpu_if.wdata : r_cpu_wdata;
        granted_if.rw    = w_take_cpu ? s_cpu_if.rw    : r_cpu_rw;

        s_cpu_if.wait_req = granted_if.wait_req;
        s_cpu_if.err      = granted_if.err;

        if (w_dm_en) s_dm_if.wait_req = 1'b1;    // DM is queued

    end else if (w_busy_dm) begin
        granted_if.addr  = w_take_dm ? s_dm_if.addr  : r_dm_addr;
        granted_if.size  = w_take_dm ? s_dm_if.size  : r_dm_size;
        granted_if.wdata = w_take_dm ? s_dm_if.wdata : r_dm_wdata;
        granted_if.rw    = w_take_dm ? s_dm_if.rw    : r_dm_rw;

        s_dm_if.wait_req = granted_if.wait_req;
        s_dm_if.err      = granted_if.err;

        if (w_cpu_en) s_cpu_if.wait_req = 1'b1;   // CPU is queued

    end else begin
        if (w_cpu_en) s_cpu_if.wait_req = 1'b1;
        if (w_dm_en)  s_dm_if.wait_req  = 1'b1;
    end
end

assign s_cpu_if.rdata = granted_if.rdata;
assign s_dm_if.rdata  = granted_if.rdata;

// Bursts are not supported through the hub
assign granted_if.burst_en  = 1'b0;
assign s_cpu_if.beat_valid  = 1'b0;
assign s_dm_if.beat_valid   = 1'b0;

// ============================================================
// Demux to SoC, external and SRAM
// ============================================================

friscv_mem_if sram_if ();

logic w_match_ext, w_match_sram;
assign w_match_ext  = (granted_if.addr - addr_t'( MEM_BASE)) < addr_t'( MEM_SIZE);
assign w_match_sram = (granted_if.addr - addr_t'(SRAM_BASE)) < addr_t'(SRAM_SIZE);

logic w_sel_ext, w_sel_sram, w_sel_sys;
assign w_sel_ext = w_match_ext && !w_sel_sram;
assign w_sel_sram = w_match_sram; 
assign w_sel_sys  = !w_sel_ext && !w_sel_sram;

assign m_ext_if.addr     = granted_if.addr;
assign m_ext_if.size     = granted_if.size;
assign m_ext_if.wdata    = granted_if.wdata;
assign m_ext_if.rw       = w_sel_ext ? granted_if.rw : RW_IDLE;
assign m_ext_if.burst_en = 1'b0;

assign m_sys_if.addr     = granted_if.addr;
assign m_sys_if.size     = granted_if.size;
assign m_sys_if.wdata    = granted_if.wdata;
assign m_sys_if.rw       = w_sel_sys ? granted_if.rw : RW_IDLE;
assign m_sys_if.burst_en = 1'b0;

assign sram_if.addr      = granted_if.addr;
assign sram_if.size      = granted_if.size;
assign sram_if.wdata     = granted_if.wdata;
assign sram_if.rw        = w_sel_sram ? granted_if.rw : RW_IDLE;
assign sram_if.burst_en  = 1'b0;

assign granted_if.rdata      = w_sel_ext ? m_ext_if.rdata      : w_sel_sram ? sram_if.rdata      : m_sys_if.rdata;
assign granted_if.wait_req   = w_sel_ext ? m_ext_if.wait_req   : w_sel_sram ? sram_if.wait_req   : m_sys_if.wait_req;
assign granted_if.err        = w_sel_ext ? m_ext_if.err        : w_sel_sram ? sram_if.err        : m_sys_if.err;
assign granted_if.beat_valid = w_sel_ext ? m_ext_if.beat_valid : w_sel_sram ? sram_if.beat_valid : m_sys_if.beat_valid;

// ============================================================
// SRAM block
// ============================================================

logic        sram_req, sram_gnt, sram_we, sram_rvalid;
logic [31:0] sram_addr, sram_wdata, sram_rdata;
logic [3:0]  sram_be;

friscv_to_mem #(
    .REGISTER_REQ ( 0 )
) sram_mem_if (
    .i_clk       ( i_clk       ),
    .i_rstn      ( i_rstn      ),
    .req_o       ( sram_req    ),
    .addr_o      ( sram_addr   ),
    .we_o        ( sram_we     ),
    .wdata_o     ( sram_wdata  ),
    .be_o        ( sram_be     ),
    .gnt_i       ( sram_gnt    ),
    .rvalid_i    ( sram_rvalid ),
    .err_i       ( 1'b0        ),
    .other_err_i ( 1'b0        ),
    .rdata_i     ( sram_rdata  ),
    .mem_if      ( sram_if     )
);

tc_sram #(
    .NumWords  ( SRAM_SIZE/4 ),
    .DataWidth ( 32          ),
    .ByteWidth ( 8           ),
    .NumPorts  ( 1           ),
    .Latency   ( 1           )
) sram (
    .clk_i   ( i_clk                            ),
    .rst_ni  ( i_rstn                           ),
    .req_i   ( sram_req                         ),
    .we_i    ( sram_we                          ),
    .addr_i  ( sram_addr[$clog2(SRAM_SIZE)-1:2] ),
    .wdata_i ( sram_wdata                       ),
    .be_i    ( sram_be                          ),
    .rdata_o ( sram_rdata                       )
);

assign sram_gnt = 1'b1;
always_ff @(posedge i_clk) begin
    if (!i_rstn) sram_rvalid <= 1'b0;
    else         sram_rvalid <= sram_req;
end


endmodule

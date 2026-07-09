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
 * This module implements an adapter between the FRISC-V core's memory interface (friscv_mem_if) and a full AXI4 master interface.
 * It supports single-beat and burst transactions of BURST_LEN beats, which can be configured as needed.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_axi4_full_adapter #(
    localparam BURST_LEN = 8  // TODO calculate this from cache size when implemented
) (
    input  logic                    i_clk,
    input  logic                    i_rstn,
    friscv_mem_if.slave             mem_if,

    // Write address channel
    output logic                    m_axi_awvalid,
    input  logic                    m_axi_awready,
    output logic [31:0]             m_axi_awaddr,
    output mem_width_e              m_axi_awsize,
    output logic [3:0]              m_axi_awcache,
    output logic [2:0]              m_axi_awprot,
    output logic [1:0]              m_axi_awburst,
    output logic [7:0]              m_axi_awlen,
    output logic                    m_axi_awlock,
    output logic [3:0]              m_axi_awqos,

    // Write data channel
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,
    output logic                    m_axi_wlast,
    output data_t                   m_axi_wdata,
    output logic [DATA_WIDTH/8-1:0] m_axi_wstrb,

    // Write response channel
    input  logic                    m_axi_bvalid,
    output logic                    m_axi_bready,
    input  logic [1:0]              m_axi_bresp,

    // Read address channel
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,
    output logic [31:0]             m_axi_araddr,
    output mem_width_e              m_axi_arsize,
    output logic [3:0]              m_axi_arcache,
    output logic [2:0]              m_axi_arprot,
    output logic [1:0]              m_axi_arburst,
    output logic [7:0]              m_axi_arlen,
    output logic                    m_axi_arlock,
    output logic [3:0]              m_axi_arqos,

    // Read data channel
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready,
    input  logic                    m_axi_rlast,
    input  data_t                   m_axi_rdata,
    input  logic [1:0]              m_axi_rresp
);

typedef enum logic [2:0] {
    S_IDLE,
    S_W_ADDR,
    S_W_DATA,
    S_W_RET,
    S_R_ADDR,
    S_R_DATA
} state_e;

state_e r_state, w_next_state;

// Latched transaction parameters
mem_width_e  r_size;
rw_cmd_e     r_rw;
logic        r_burst_en;
logic [31:0] r_addr;
data_t       r_wdata, r_rdata;
logic        r_err;

// Write-back FIFO
// Cache fills from cycle 0 at 1 word/cycle
// FIFO can never overflow: cache pushes exactly BURST_LEN words and AXI drains at most
data_t r_fifo [BURST_LEN];

localparam FIFO_PTR_W = $clog2(BURST_LEN);

logic [FIFO_PTR_W-1:0] r_fifo_wptr, r_fifo_rptr;
logic [FIFO_PTR_W:0]   r_fifo_count;
logic                  fifo_empty;
logic                  fifo_wen, fifo_ren;

// Push counter: tracks how many words have been pushed into the FIFO
// Set to 1 on the first push in S_IDLE, increments to BURST_LEN
logic [FIFO_PTR_W:0] r_push_cnt;

assign fifo_empty = (r_fifo_count == '0);

// Push word 0 while still in S_IDLE, push words 1..BURST_LEN-1 via r_push_cnt
assign fifo_wen = ((r_state == S_IDLE) && (mem_if.rw == RW_WRITE) && mem_if.burst_en) ||
                  (r_burst_en && (r_rw == RW_WRITE) &&
                   (r_push_cnt > '0) && (r_push_cnt < BURST_LEN[FIFO_PTR_W:0]));

// Pop when AXI W channel accepts a burst beat
assign fifo_ren = (r_state == S_W_DATA) && r_burst_en && !fifo_empty && m_axi_wready;

// Data width and alignment
logic [DATA_WIDTH/8-1:0] base_strb;
logic [$clog2(DATA_WIDTH/8)-1:0] byte_offset;
assign byte_offset = r_addr[$clog2(DATA_WIDTH/8)-1:0];
assign m_axi_wstrb = base_strb << byte_offset;

always_comb begin
    case (r_size)
        WIDTH_I8, WIDTH_U8:   base_strb = 4'b0001;
        WIDTH_I16, WIDTH_U16: base_strb = 4'b0011;
        default:              base_strb = 4'b1111;
    endcase
end

logic w_read_completing, w_write_completing;
assign w_read_completing  = m_axi_rvalid && m_axi_rready;
assign w_write_completing = m_axi_bvalid && m_axi_bready;

// Constant assignments
assign mem_if.rdata  = w_read_completing ? m_axi_rdata : r_rdata;
assign m_axi_awaddr  = r_addr;
assign m_axi_awsize  = r_size;
assign m_axi_awcache = 4'b0011;
assign m_axi_awprot  = 3'b000;
assign m_axi_awburst = 2'b01;
assign m_axi_awlen   = r_burst_en ? (BURST_LEN - 1) : 8'h00;
assign m_axi_awlock  = 1'b0;
assign m_axi_awqos   = 4'h0;

// Burst writes stream from FIFO, single writes use the latched r_wdata register
assign m_axi_wdata   = r_burst_en ? r_fifo[r_fifo_rptr] : r_wdata;

assign m_axi_araddr  = r_addr;
assign m_axi_arsize  = r_size;
assign m_axi_arcache = 4'b0011;
assign m_axi_arprot  = 3'b000;
assign m_axi_arburst = 2'b01;
assign m_axi_arlen   = r_burst_en ? (BURST_LEN - 1) : 8'h00;
assign m_axi_arlock  = 1'b0;
assign m_axi_arqos   = 4'h0;

assign mem_if.wait_req   = w_next_state != S_IDLE;
assign mem_if.beat_valid = r_burst_en && (r_state == S_R_DATA) && m_axi_rvalid && m_axi_rready;
assign mem_if.err        = w_read_completing  ? |m_axi_rresp :
                           w_write_completing ? |m_axi_bresp : 1'b0;

// Clocked logic
always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_rw         <= RW_IDLE;
        r_burst_en   <= 1'b0;
        r_state      <= S_IDLE;
        r_push_cnt   <= '0;
        r_fifo_wptr  <= '0;
        r_fifo_rptr  <= '0;
        r_fifo_count <= '0;
        r_err        <= 1'b0;
        {r_addr, r_wdata, r_rdata, r_size} <= '0;
    end else begin
        r_state <= w_next_state;

        if (r_state == S_IDLE && mem_if.rw != RW_IDLE) begin
            r_rw       <= mem_if.rw;
            r_addr     <= mem_if.addr;
            r_wdata    <= mem_if.wdata;
            r_size     <= mem_if.size;
            r_burst_en <= mem_if.burst_en;
            r_err      <= 1'b0;
        end

        if (w_read_completing) begin
            r_rdata <= m_axi_rdata;
            r_err   <= |m_axi_rresp;
        end

        if (w_write_completing) begin
            r_err <= |m_axi_bresp;
        end

        if (fifo_wen) begin
            r_fifo[r_fifo_wptr] <= mem_if.wdata;
            r_fifo_wptr         <= r_fifo_wptr + 1;
        end

        if (fifo_ren) begin
            r_fifo_rptr <= r_fifo_rptr + 1;
        end

        if (fifo_wen && !fifo_ren)
            r_fifo_count <= r_fifo_count + 1;
        else if (!fifo_wen && fifo_ren)
            r_fifo_count <= r_fifo_count - 1;

        if ((r_state == S_IDLE) && (mem_if.rw == RW_WRITE) && mem_if.burst_en) begin
            r_push_cnt <= 1;
        end else if (r_burst_en && (r_rw == RW_WRITE) &&
                     (r_push_cnt > '0) && (r_push_cnt < BURST_LEN[FIFO_PTR_W:0])) begin
            r_push_cnt <= r_push_cnt + 1;
        end
    end
end

always_comb begin
    w_next_state  = r_state;
    m_axi_awvalid = 1'b0;
    m_axi_wvalid  = 1'b0;
    m_axi_wlast   = 1'b0;
    m_axi_bready  = 1'b0;
    m_axi_arvalid = 1'b0;
    m_axi_rready  = 1'b0;

    unique case (r_state)
        S_IDLE: begin
            if (mem_if.rw == RW_WRITE || mem_if.rw == RW_READ) begin
                w_next_state = (mem_if.rw == RW_WRITE) ? S_W_ADDR : S_R_ADDR;
            end
        end

        S_W_ADDR: begin
            m_axi_awvalid = 1'b1;
            w_next_state  = m_axi_awready ? S_W_DATA : S_W_ADDR;
        end

        S_W_DATA: begin
            if (r_burst_en) begin
                m_axi_wvalid = !fifo_empty;
                m_axi_wlast  = !fifo_empty && (r_fifo_count == 1);
                if (!fifo_empty && m_axi_wready && (r_fifo_count == 1)) begin
                    w_next_state = S_W_RET;
                end
            end else begin
                m_axi_wvalid = 1'b1;
                m_axi_wlast  = 1'b1;
                if (m_axi_wready) begin
                    w_next_state = S_W_RET;
                end
            end
        end

        S_W_RET: begin
            m_axi_bready = 1'b1;
            if (m_axi_bvalid) begin
                w_next_state = S_IDLE;
            end
        end

        S_R_ADDR: begin
            m_axi_arvalid = 1'b1;
            w_next_state  = m_axi_arready ? S_R_DATA : S_R_ADDR;
        end

        S_R_DATA: begin
            m_axi_rready = 1'b1;
            if (m_axi_rvalid && (!r_burst_en || m_axi_rlast)) begin
                w_next_state = S_IDLE;
            end
        end
    endcase
end

endmodule

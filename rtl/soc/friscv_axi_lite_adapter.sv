// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_axi_lite_adapter (
    input  logic        i_clk,
    input  logic        i_rstn,
    friscv_mem_if.slave mem_if,

    // Write address channel
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [31:0] m_axi_awaddr,
    output logic [2:0]  m_axi_awprot,

    // Write data channel
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    output data_t       m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,

    // Write response channel
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    input  logic [1:0]  m_axi_bresp,

    // Read address channel
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    output logic [31:0] m_axi_araddr,
    output logic [2:0]  m_axi_arprot,

    // Read data channel
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,
    input  data_t       m_axi_rdata,
    input  logic [1:0]  m_axi_rresp
);

typedef enum logic [2:0] {
    S_IDLE,
    S_W,
    S_W_RET,
    S_R_ADDR,
    S_R_DATA
} state_e;

state_e r_state, w_next_state;

// Latched transaction parameters
mem_width_e  r_size;
logic [31:0] r_addr;
data_t       r_wdata, r_rdata;

logic r_aw_done, r_w_done;
logic w_aw_hs, w_w_hs;

assign w_aw_hs = m_axi_awvalid && m_axi_awready;
assign w_w_hs  = m_axi_wvalid  && m_axi_wready;

// Data width and alignment
logic [DATA_WIDTH/8-1:0] base_strb;
logic [$clog2(DATA_WIDTH/8)-1:0] byte_offset;
assign byte_offset = r_addr[$clog2(DATA_WIDTH/8)-1:0];
assign m_axi_wstrb = base_strb << byte_offset;

always_comb begin
    case (r_size)
        WIDTH_I8, WIDTH_U8:   base_strb = 4'b0001;
        WIDTH_I16, WIDTH_U16: base_strb = 4'b0011;
        WIDTH_I32:            base_strb = 4'b1111;
        default:              base_strb = 4'b1111;
    endcase
end

logic w_read_completing, w_write_completing;
assign w_read_completing  = m_axi_rvalid && m_axi_rready;
assign w_write_completing = m_axi_bvalid && m_axi_bready;

// Constant assignments
assign m_axi_awaddr = r_addr;
assign m_axi_awprot = 3'b000;
assign m_axi_wdata  = r_wdata;
assign m_axi_araddr = r_addr;
assign m_axi_arprot = 3'b000;

assign mem_if.rdata      = w_read_completing ? m_axi_rdata : r_rdata;
assign mem_if.wait_req   = w_next_state != S_IDLE;
assign mem_if.beat_valid = 1'b0;
assign mem_if.err        = w_read_completing  ? |m_axi_rresp :
                           w_write_completing ? |m_axi_bresp : 1'b0;

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_state      <= S_IDLE;
        r_aw_done    <= 1'b0;
        r_w_done     <= 1'b0;
        r_addr       <= '0;
        r_wdata      <= '0;
        r_rdata      <= '0;
        r_size       <= WIDTH_I32;
    end else begin
        r_state <= w_next_state;
        if (r_state == S_IDLE && mem_if.rw != RW_IDLE) begin
            r_addr     <= mem_if.addr;
            r_wdata    <= mem_if.wdata;
            r_size     <= mem_if.size;
            r_aw_done  <= 1'b0;
            r_w_done   <= 1'b0;
        end
        if (r_state == S_W) begin
            if (w_aw_hs) r_aw_done <= 1'b1;
            if (w_w_hs)  r_w_done  <= 1'b1;
        end
        if (w_read_completing) r_rdata <= m_axi_rdata;
    end
end

always_comb begin
    w_next_state  = r_state;
    m_axi_awvalid = 1'b0;
    m_axi_wvalid  = 1'b0;
    m_axi_bready  = 1'b0;
    m_axi_arvalid = 1'b0;
    m_axi_rready  = 1'b0;

    case (r_state)
        S_IDLE: begin
            if (mem_if.rw == RW_WRITE || mem_if.rw == RW_READ)
                w_next_state = (mem_if.rw == RW_WRITE) ? S_W : S_R_ADDR;
        end

        S_W: begin
            m_axi_awvalid = !r_aw_done;
            m_axi_wvalid  = !r_w_done;
            if ((r_aw_done || m_axi_awready) && (r_w_done || m_axi_wready))
                w_next_state = S_W_RET;
        end

        S_W_RET: begin
            m_axi_bready = 1'b1;
            if (m_axi_bvalid) w_next_state = S_IDLE;
        end

        S_R_ADDR: begin
            m_axi_arvalid = 1'b1;
            w_next_state  = m_axi_arready ? S_R_DATA : S_R_ADDR;
        end

        S_R_DATA: begin
            m_axi_rready = 1'b1;
            if (m_axi_rvalid) w_next_state = S_IDLE;
        end

        default: ;
    endcase
end

endmodule

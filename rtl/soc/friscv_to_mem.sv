// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * Bridge between a friscv_mem_if master interface and a Pulp mem master port.
 * Single-beat transfers only, bursts are not supported and burst_en is ignored.
 */

`timescale 1ns/1ps

import friscv_pkg::*;

module friscv_to_mem #(
    parameter bit REGISTER_REQ = 1'b0
) (
    input  logic         i_clk,
    input  logic         i_rstn,

    output logic         req_o,
    output addr_t        addr_o,
    output logic         we_o,
    output data_t        wdata_o,
    output logic [3:0]   be_o,
    input  logic         gnt_i,
    input  logic         rvalid_i,
    input  logic         err_i,
    input  logic         other_err_i,
    input  data_t        rdata_i,

    friscv_mem_if.slave  mem_if
);

typedef enum logic [1:0] {
    S_IDLE,
    S_REQ,
    S_RSP
} state_e;

state_e state_q, state_d;

addr_t      addr_q;
data_t      wdata_q;
mem_width_e size_q;
logic       we_q;

logic w_issue;
assign w_issue = !REGISTER_REQ && (state_q == S_IDLE) && (mem_if.rw != RW_IDLE);

mem_width_e w_size;
assign w_size = w_issue ? mem_if.size : size_q;

logic [3:0] base_be;
always_comb begin
    case (w_size)
        WIDTH_I8, WIDTH_U8:   base_be = 4'b0001;
        WIDTH_I16, WIDTH_U16: base_be = 4'b0011;
        WIDTH_I32:            base_be = 4'b1111;
        default:              base_be = 4'b1111;
    endcase
end

assign addr_o  = w_issue ? mem_if.addr : addr_q;
assign we_o    = w_issue ? (mem_if.rw == RW_WRITE) : we_q;
assign wdata_o = w_issue ? mem_if.wdata : wdata_q;
assign be_o    = base_be << addr_o[1:0];

logic w_completing;
assign w_completing = (state_q == S_RSP) && rvalid_i;

assign mem_if.rdata      = rdata_i;
assign mem_if.err        = w_completing && (err_i || other_err_i);
assign mem_if.wait_req   = (state_q == S_RSP) ? !rvalid_i : 1'b1;
assign mem_if.beat_valid = 1'b0;

assign req_o = w_issue || (state_q == S_REQ);

always_comb begin
    state_d = state_q;
    case (state_q)
        S_IDLE:  if (mem_if.rw != RW_IDLE) state_d = (w_issue && gnt_i) ? S_RSP : S_REQ;
        S_REQ:   if (gnt_i)                state_d = S_RSP;
        S_RSP:   if (rvalid_i)             state_d = S_IDLE;
        default: state_d = S_IDLE;
    endcase
end

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        state_q <= S_IDLE;
        addr_q  <= '0;
        wdata_q <= '0;
        size_q  <= WIDTH_I32;
        we_q    <= 1'b0;
    end else begin
        state_q <= state_d;
        if (state_q == S_IDLE) begin
            addr_q  <= mem_if.addr;
            wdata_q <= mem_if.wdata;
            size_q  <= mem_if.size;
            we_q    <= mem_if.rw == RW_WRITE;
        end
    end
end

endmodule

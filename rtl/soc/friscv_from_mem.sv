// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * Bridge between Pulp mem master port and a friscv_mem_if master interface.
 */

`timescale 1ns/1ps

import friscv_pkg::*;

module friscv_from_mem (
    input  logic         i_clk,
    input  logic         i_rstn,

    input  logic         req_i,
    input  addr_t        addr_i,
    input  logic         we_i,
    input  data_t        wdata_i,
    input  logic [3:0]   be_i,
    output logic         gnt_o,
    output logic         rvalid_o,
    output logic         err_o,
    output logic         other_err_o,
    output data_t        rdata_o,

    friscv_mem_if.master mem_if
);

typedef enum logic {
    S_IDLE,
    S_BUSY
} state_e;

state_e state_q, state_d;

// Latched transaction fields
addr_t      addr_q;
data_t      wdata_q;
logic [3:0] be_q;
logic       we_q;

// The DM aligns be to the address, so the access width is its population
// count; the byte offset is re-derived from the address downstream.
mem_width_e size;
always_comb begin
    case (be_q)
        4'b0001, 4'b0010, 4'b0100, 4'b1000: size = WIDTH_U8;
        4'b0011, 4'b1100:                   size = WIDTH_U16;
        default:                            size = WIDTH_I32;
    endcase
end

// Constant request fields
assign mem_if.addr     = addr_q;
assign mem_if.size     = size;
assign mem_if.wdata    = wdata_q;
assign mem_if.burst_en = 1'b0;

// Read data / errors returned to the DM
assign rdata_o     = mem_if.rdata;
assign other_err_o = 1'b0;

always_comb begin
    state_d = state_q;

    gnt_o    = 1'b0;
    rvalid_o = 1'b0;
    err_o    = 1'b0;

    mem_if.rw = RW_IDLE;

    case (state_q)
        S_IDLE: begin
            gnt_o = req_i;
            if (req_i) state_d = S_BUSY;
        end

        S_BUSY: begin
            mem_if.rw = we_q ? RW_WRITE : RW_READ;
            if (!mem_if.wait_req) begin
                rvalid_o = 1'b1;
                err_o    = mem_if.err;
                state_d     = S_IDLE;
            end
        end

        default: state_d = S_IDLE;
    endcase
end

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        state_q <= S_IDLE;
        addr_q  <= '0;
        wdata_q <= '0;
        be_q    <= '0;
        we_q    <= 1'b0;
    end else begin
        state_q <= state_d;
        if (state_q == S_IDLE && req_i) begin
            addr_q  <= addr_i;
            wdata_q <= wdata_i;
            be_q    <= be_i;
            we_q    <= we_i;
        end
    end
end

endmodule

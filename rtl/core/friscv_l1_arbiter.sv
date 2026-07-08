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
 * This module implements a state-machine-based arbiter for the shared memory interfaces of a single core.
 * It takes requests from IF and MEM stages, grants one, and forwards it to the external memory interface.
 * A grant is held until the transaction completes (wait deasserts), then priority is rotated.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_l1_arbiter (
    input  logic       i_clk,
    input  logic       i_rstn,

    // Instruction Memory Interface
    input  addr_t      i_inst_addr,
    output data_t      o_inst_data,
    input  logic       i_inst_en,
    output logic       o_inst_wait,
    output logic       o_inst_err,

    // Data Memory Interface
    input  addr_t      i_data_addr,
    input  mem_width_e i_data_size,
    input  data_t      i_data_wdata,
    output data_t      o_data_rdata,
    input  logic       i_data_en,
    input  logic       i_data_wr,
    output logic       o_data_wait,
    input  amo_op_e    i_amo_op,
    output logic       o_data_err,

    // External Interface
    output addr_t      o_mem_addr,
    output mem_width_e o_mem_size,
    output data_t      o_mem_wdata,
    input  data_t      i_mem_rdata,
    output rw_cmd_e    o_mem_rw,
    input  logic       i_mem_wait,
    input  logic       i_mem_err,
    output amo_op_e    o_amo_op,
    output logic       o_grant_inst,
    output logic       o_grant_start,
    output logic       o_grant_start_inst
);

// FSM States
typedef enum logic [1:0] {
    S_IDLE,
    S_GRANT_INST,
    S_GRANT_DATA
} state_t;

state_t r_state, w_next_state;
logic r_priority_flag;  // 0=Inst, 1=Data

addr_t      r_inst_addr;
addr_t      r_data_addr;
mem_width_e r_data_size;
data_t      r_data_wdata;
logic       r_data_wr;
amo_op_e    r_data_amo;

// FSM Update
always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_state <= S_IDLE;
        r_priority_flag <= 1'b0;
        r_inst_addr  <= '0;
        r_data_addr  <= '0;
        r_data_size  <= WIDTH_I32;
        r_data_wdata <= '0;
        r_data_wr    <= 1'b0;
        r_data_amo   <= AMO_NONE;
    end else begin
        r_state <= w_next_state;

        // Freeze the request attributes for the lifetime of the granted bus transaction.
        if (r_state == S_IDLE) begin
            if (w_next_state == S_GRANT_INST) begin
                r_inst_addr <= i_inst_addr;
            end
            if (w_next_state == S_GRANT_DATA) begin
                r_data_addr  <= i_data_addr;
                r_data_size  <= i_data_size;
                r_data_wdata <= i_data_wdata;
                r_data_wr    <= i_data_wr;
                r_data_amo   <= i_amo_op;
            end
        end

        // Rotate priority on transaction completion
        if (r_state != S_IDLE && w_next_state == S_IDLE) begin
            r_priority_flag <= !r_priority_flag;
        end
    end
end

// Next State Logic
always_comb begin
    w_next_state = r_state;
    case (r_state)
        S_IDLE: begin
            if (i_data_en && i_inst_en) begin
                w_next_state = (r_priority_flag) ? S_GRANT_DATA : S_GRANT_INST;
            end else if (i_data_en) begin
                w_next_state = S_GRANT_DATA;
            end else if (i_inst_en) begin
                w_next_state = S_GRANT_INST;
            end
        end
        S_GRANT_INST: begin
            if (!i_mem_wait) w_next_state = S_IDLE;
        end
        S_GRANT_DATA: begin
            if (!i_mem_wait) w_next_state = S_IDLE;
        end
        default: ;
    endcase
end

// Output Logic
always_comb begin
    o_mem_addr  = 32'h0;
    o_mem_size  = WIDTH_I32;
    o_mem_wdata = 32'h0;
    o_mem_rw    = RW_IDLE;
    o_inst_wait = 1'b0;
    o_data_wait = 1'b0;
    o_inst_err  = 1'b0;
    o_data_err  = 1'b0;
    o_amo_op    = AMO_NONE;

    case (r_state)
        S_IDLE: begin
            // If requesting, insert wait cycle for arbitration
            if (i_inst_en) o_inst_wait = 1'b1;
            if (i_data_en) o_data_wait = 1'b1;
        end
        S_GRANT_INST: begin
            o_mem_addr  = r_inst_addr;
            o_mem_size  = WIDTH_I32;
            o_mem_rw    = RW_READ;
            o_inst_wait = i_mem_wait;
            o_inst_err  = i_mem_err;
            if (i_data_en) o_data_wait = 1'b1;
        end
        S_GRANT_DATA: begin
            o_mem_addr  = r_data_addr;
            o_mem_size  = r_data_size;
            o_mem_wdata = r_data_wdata;
            o_mem_rw    = r_data_wr ? RW_WRITE : RW_READ;
            o_data_wait = i_mem_wait;
            o_amo_op    = r_data_amo;
            o_data_err  = i_mem_err;
            if (i_inst_en) o_inst_wait = 1'b1;
        end
        default: ;
    endcase
end

assign o_inst_data  = i_mem_rdata;
assign o_data_rdata = i_mem_rdata;
assign o_grant_inst = (r_state == S_GRANT_INST);
assign o_grant_start = (r_state == S_IDLE) && (w_next_state != S_IDLE);
assign o_grant_start_inst = (r_state == S_IDLE) && (w_next_state == S_GRANT_INST);

endmodule

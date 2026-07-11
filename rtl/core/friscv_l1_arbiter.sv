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
 * State-machine-based arbiter for the shared memory interfaces of a single core.
 * Takes requests from IF and MEM, grants one, forwards it to the external memory
 * interface. A grant is held until the transaction completes, then priority rotates.
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

    // Status to the MMU
    output logic       o_grant_inst,
    output logic       o_grant_start,
    output logic       o_grant_start_inst,
    output logic       o_grant_held
);

// S_IDLE      : bus free, a request present on the core inputs is issued
//               combinationally in this same cycle.
// S_HOLD_INST : an instruction fetch was issued and the memory asserted wait;
//               the request is frozen in r_inst_addr and re-driven until done.
// S_HOLD_DATA : same for a data access.
typedef enum logic [1:0] {
    S_IDLE,
    S_HOLD_INST,
    S_HOLD_DATA
} state_t;

state_t r_state, w_next_state;
logic   r_data_priority;

addr_t      r_inst_addr;
addr_t      r_data_addr;
mem_width_e r_data_size;
data_t      r_data_wdata;
logic       r_data_wr;
amo_op_e    r_data_amo;

// ============================================================
// Issue selection
// ===========================================================
logic w_take_inst, w_take_data, w_take_any;

always_comb begin
    w_take_inst = 1'b0;
    w_take_data = 1'b0;
    if (r_state == S_IDLE) begin
        if (i_inst_en && i_data_en) begin
            w_take_inst = !r_data_priority;
            w_take_data =  r_data_priority;
        end else begin
            w_take_inst = i_inst_en;
            w_take_data = i_data_en;
        end
    end
end

assign w_take_any = w_take_inst | w_take_data;

// A transaction is on the bus this cycle if it is being issued now, or held
logic w_busy_inst, w_busy_data, w_busy;
assign w_busy_inst = w_take_inst | (r_state == S_HOLD_INST);
assign w_busy_data = w_take_data | (r_state == S_HOLD_DATA);
assign w_busy      = w_busy_inst | w_busy_data;

// Transaction retires this cycle
logic w_done;
assign w_done = w_busy & ~i_mem_wait;

// Must park in a HOLD state, issued this cycle but the memory did not complete
logic w_park;
assign w_park = w_take_any & i_mem_wait;

// ============================================================
// Next state
// ============================================================
always_comb begin
    w_next_state = r_state;
    case (r_state)
        S_IDLE:      if (w_park) w_next_state = w_take_inst ? S_HOLD_INST : S_HOLD_DATA;
        S_HOLD_INST,
        S_HOLD_DATA: if (!i_mem_wait) w_next_state = S_IDLE;
        default:     w_next_state = S_IDLE;
    endcase
end

// ============================================================
// Sequential
// ============================================================
always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_state         <= S_IDLE;
        r_data_priority <= 1'b0;
        r_inst_addr     <= '0;
        r_data_addr     <= '0;
        r_data_size     <= WIDTH_I32;
        r_data_wdata    <= '0;
        r_data_wr       <= 1'b0;
        r_data_amo      <= AMO_NONE;
    end else begin
        r_state <= w_next_state;

        // Freeze the request if it is going to be held
        if (w_park && w_take_inst) begin
            r_inst_addr  <= i_inst_addr;
        end
        if (w_park && w_take_data) begin
            r_data_addr  <= i_data_addr;
            r_data_size  <= i_data_size;
            r_data_wdata <= i_data_wdata;
            r_data_wr    <= i_data_wr;
            r_data_amo   <= i_amo_op;
        end

        // Rotate priority on completion
        if (w_done) begin
            r_data_priority <= w_busy_inst;
        end
    end
end

// ============================================================
// Output
// ============================================================
always_comb begin
    o_mem_addr  = '0;
    o_mem_size  = WIDTH_I32;
    o_mem_wdata = '0;
    o_mem_rw    = RW_IDLE;
    o_amo_op    = AMO_NONE;
    o_inst_wait = 1'b0;
    o_data_wait = 1'b0;
    o_inst_err  = 1'b0;
    o_data_err  = 1'b0;

    if (w_busy_inst) begin
        o_mem_addr  = w_take_inst ? i_inst_addr : r_inst_addr;
        o_mem_size  = WIDTH_I32;
        o_mem_rw    = RW_READ;

        o_inst_wait = i_mem_wait;
        o_inst_err  = i_mem_err;

        if (i_data_en) o_data_wait = 1'b1;   // data is queued

    end else if (w_busy_data) begin
        o_mem_addr  = w_take_data ? i_data_addr  : r_data_addr;
        o_mem_size  = w_take_data ? i_data_size  : r_data_size;
        o_mem_wdata = w_take_data ? i_data_wdata : r_data_wdata;
        o_mem_rw    = (w_take_data ? i_data_wr : r_data_wr) ? RW_WRITE : RW_READ;
        o_amo_op    = w_take_data ? i_amo_op     : r_data_amo;

        o_data_wait = i_mem_wait;
        o_data_err  = i_mem_err;

        if (i_inst_en) o_inst_wait = 1'b1;   // fetch is queued

    end else begin
        if (i_inst_en) o_inst_wait = 1'b1;
        if (i_data_en) o_data_wait = 1'b1;
    end
end

assign o_inst_data  = i_mem_rdata;
assign o_data_rdata = i_mem_rdata;

assign o_grant_inst       = w_busy_inst;
assign o_grant_start      = w_take_any;
assign o_grant_start_inst = w_take_inst;
assign o_grant_held       = (r_state != S_IDLE);

endmodule

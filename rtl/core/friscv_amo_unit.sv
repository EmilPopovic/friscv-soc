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
 * This module implements the AMO unit of the FRISC-V core, which handles atomic memory operations.
 * Make sure that the input request is stable until the entire AMO sequence completes.
 * In the case of an error, wait will be deasserted immediately, and the upstream sees the error signal on the same cycle.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_amo_unit (
    input  logic    i_clk,
    input  logic    i_rstn,

    // Requested atomic operation
    input  amo_op_e i_amo_op,

    // Core interface
    input  data_t   i_rs2_val,
    output data_t   o_core_load_data,
    output logic    o_core_wait,

    // External interface
    input  logic    i_mem_wait,
    input  logic    i_mem_err,
    output rw_cmd_e o_mem_rw,
    input  data_t   i_mem_load_data,
    output data_t   o_mem_store_data
);

typedef enum logic [1:0] {
    S_IDLE,
    S_LOAD,
    S_STORE
} state_e;

state_e  r_state, w_next_state;
data_t   r_load_data;
data_t   w_load_data;  // r_load_data, or live rdata on the cycle the load completes
amo_op_e r_amo_op;
data_t   r_rs2_val;

// Use live rdata on load-completion cycle (r_load_data not yet updated),
// use the registered capture for all S_STORE cycles
assign w_load_data = (r_state == S_LOAD && !i_mem_wait) ? i_mem_load_data : r_load_data;

assign o_core_load_data = w_load_data;

// Core should wait if
//  1) On the initiating cycle when AMO is idle
//  2) During a load
//  3) During a stall, except when downstream is not waiting, that is the last cycle
assign o_core_wait = ((r_state == S_IDLE)  && (i_amo_op != AMO_NONE)) ||
                     ((r_state == S_LOAD)  && !i_mem_err) ||
                     ((r_state == S_STORE) && i_mem_wait);

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_state     <= S_IDLE;
        r_load_data <= 32'b0;
        r_amo_op    <= AMO_NONE;
        r_rs2_val   <= 32'b0;
    end else begin
        r_state <= w_next_state;

        // Freeze AMO op/operand for the whole LOAD-STORE sequence.
        if (r_state == S_IDLE && i_amo_op != AMO_NONE) begin
            r_amo_op  <= i_amo_op;
            r_rs2_val <= i_rs2_val;
        end

        if (w_next_state == S_IDLE)
            r_amo_op <= AMO_NONE;

        // Capture load data when load completes
        if (r_state == S_LOAD && !i_mem_wait) begin
            r_load_data <= i_mem_load_data;
        end
    end
end

// Calculate op result using w_load_data, which is stable throughout S_STORE
always_comb begin
    case (r_amo_op)
        AMO_NONE: o_mem_store_data = w_load_data;
        AMO_SWAP: o_mem_store_data = r_rs2_val;
        AMO_ADD:  o_mem_store_data = w_load_data + r_rs2_val;
        AMO_XOR:  o_mem_store_data = w_load_data ^ r_rs2_val;
        AMO_AND:  o_mem_store_data = w_load_data & r_rs2_val;
        AMO_OR:   o_mem_store_data = w_load_data | r_rs2_val;
        AMO_MIN:  o_mem_store_data = ($signed(w_load_data) < $signed(r_rs2_val)) ? w_load_data : r_rs2_val;
        AMO_MAX:  o_mem_store_data = ($signed(w_load_data) > $signed(r_rs2_val)) ? w_load_data : r_rs2_val;
        AMO_MINU: o_mem_store_data = (w_load_data < r_rs2_val) ? w_load_data : r_rs2_val;
        AMO_MAXU: o_mem_store_data = (w_load_data > r_rs2_val) ? w_load_data : r_rs2_val;
        default:  o_mem_store_data = w_load_data;
    endcase
end

// State transition logic
always_comb begin
    case (r_state)
        S_IDLE: begin
            w_next_state = (i_amo_op != AMO_NONE) ? S_LOAD : S_IDLE;
        end
        S_LOAD: begin
            w_next_state = i_mem_wait ? S_LOAD :
                           i_mem_err  ? S_IDLE :
                                        S_STORE;
        end
        S_STORE: begin
            w_next_state = i_mem_wait ? S_STORE : S_IDLE;
        end
        default: begin
            w_next_state = r_state;
        end
    endcase
end

// Output decode
always_comb begin
    case (r_state)
        S_IDLE:  o_mem_rw = (i_amo_op != AMO_NONE) ? RW_READ : RW_IDLE;
        S_LOAD:  o_mem_rw = RW_READ;
        S_STORE: o_mem_rw = RW_WRITE;
        default: o_mem_rw = RW_IDLE;
    endcase
end

endmodule

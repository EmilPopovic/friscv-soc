// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the AMO unit of the FRISC-V core, which handles atomic memory operations.
 * Make sure that the input request is stable until the entire AMO sequence completes.
 * In the case of an error, wait will be deasserted immediately, and the upstream sees the error signal on the same cycle.
 */

module friscv_amo_unit import friscv_pkg::*; (
    input  logic    clk_i,
    input  logic    rst_ni,

    // Requested atomic operation
    input  amo_op_e amo_op_i,

    // Core interface
    input  data_t   rs2_val_i,
    output data_t   core_load_data_o,
    output logic    core_wait_o,

    // External interface
    input  logic    mem_wait_i,
    input  logic    mem_err_i,
    output rw_cmd_e mem_rw_o,
    input  data_t   mem_load_data_i,
    output data_t   mem_store_data_o
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
assign w_load_data = (r_state == S_LOAD && !mem_wait_i) ? mem_load_data_i : r_load_data;

assign core_load_data_o = w_load_data;

// Core should wait if
//  1) On the initiating cycle when AMO is idle
//  2) During a load
//  3) During a stall, except when downstream is not waiting, that is the last cycle
assign core_wait_o = ((r_state == S_IDLE)  && (amo_op_i != AMO_NONE)) ||
                      ((r_state == S_LOAD)  && !mem_err_i) ||
                      ((r_state == S_STORE) && mem_wait_i);

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        r_load_data <= 32'b0;
        r_amo_op    <= AMO_NONE;
        r_rs2_val   <= 32'b0;
    end else begin
        // Freeze AMO op/operand for the whole LOAD-STORE sequence.
        if (r_state == S_IDLE && amo_op_i != AMO_NONE) begin
            r_amo_op  <= amo_op_i;
            r_rs2_val <= rs2_val_i;
        end

        if (w_next_state == S_IDLE)
            r_amo_op <= AMO_NONE;

        // Capture load data when load completes
        if (r_state == S_LOAD && !mem_wait_i)
            r_load_data <= mem_load_data_i;
    end
end

always_comb begin
    case (r_amo_op)
        AMO_NONE: mem_store_data_o = r_load_data;
        AMO_SWAP: mem_store_data_o = r_rs2_val;
        AMO_ADD:  mem_store_data_o = r_load_data + r_rs2_val;
        AMO_XOR:  mem_store_data_o = r_load_data ^ r_rs2_val;
        AMO_AND:  mem_store_data_o = r_load_data & r_rs2_val;
        AMO_OR:   mem_store_data_o = r_load_data | r_rs2_val;
        AMO_MIN:  mem_store_data_o = ($signed(r_load_data) < $signed(r_rs2_val)) ? r_load_data : r_rs2_val;
        AMO_MAX:  mem_store_data_o = ($signed(r_load_data) > $signed(r_rs2_val)) ? r_load_data : r_rs2_val;
        AMO_MINU: mem_store_data_o = (r_load_data < r_rs2_val) ? r_load_data : r_rs2_val;
        AMO_MAXU: mem_store_data_o = (r_load_data > r_rs2_val) ? r_load_data : r_rs2_val;
        default:  mem_store_data_o = r_load_data;
    endcase
end

// State machine
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) r_state <= S_IDLE;
    else         r_state <= w_next_state;
end

always_comb begin
    case (r_state)
        S_IDLE:
            w_next_state = (amo_op_i != AMO_NONE) ? S_LOAD : S_IDLE;
        S_LOAD:
            w_next_state = mem_wait_i ? S_LOAD :
                           mem_err_i  ? S_IDLE :
                                        S_STORE;
        S_STORE:
            w_next_state = mem_wait_i ? S_STORE : S_IDLE;
        default: w_next_state = S_IDLE;
    endcase
end

// Output decode
always_comb begin
    case (r_state)
        S_IDLE:  mem_rw_o = (amo_op_i != AMO_NONE) ? RW_READ : RW_IDLE;
        S_LOAD:  mem_rw_o = RW_READ;
        S_STORE: mem_rw_o = RW_WRITE;
        default: mem_rw_o = RW_IDLE;
    endcase
end

endmodule

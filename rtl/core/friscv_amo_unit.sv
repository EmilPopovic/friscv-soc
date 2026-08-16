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
    StIdle,
    StLoad,
    StStore
} state_e;

state_e  state_q, state_d;
data_t   load_data_q, load_data_d;
amo_op_e amo_op_q;
data_t   rs2_val_q;

// Use live rdata on load-completion cycle (load_data_q not yet updated),
// use the registered capture for all StStore cycles
assign load_data_d = (state_q == StLoad && !mem_wait_i) ? mem_load_data_i : load_data_q;

assign core_load_data_o = load_data_d;

// Core should wait if
//  1) On the initiating cycle when AMO is idle
//  2) During a load
//  3) During a stall, except when downstream is not waiting, that is the last cycle
assign core_wait_o = ((state_q == StIdle)  && (amo_op_i != AMO_NONE)) ||
                      ((state_q == StLoad)  && !mem_err_i) ||
                      ((state_q == StStore) && mem_wait_i);

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        load_data_q <= 32'b0;
        amo_op_q    <= AMO_NONE;
        rs2_val_q   <= 32'b0;
    end else begin
        // Freeze AMO op/operand for the whole LOAD-STORE sequence.
        if (state_q == StIdle && amo_op_i != AMO_NONE) begin
            amo_op_q  <= amo_op_i;
            rs2_val_q <= rs2_val_i;
        end

        if (state_d == StIdle)
            amo_op_q <= AMO_NONE;

        // Capture load data when load completes
        if (state_q == StLoad && !mem_wait_i)
            load_data_q <= mem_load_data_i;
    end
end

always_comb begin
    unique case (amo_op_q)
        AMO_NONE: mem_store_data_o = load_data_q;
        AMO_SWAP: mem_store_data_o = rs2_val_q;
        AMO_ADD:  mem_store_data_o = load_data_q + rs2_val_q;
        AMO_XOR:  mem_store_data_o = load_data_q ^ rs2_val_q;
        AMO_AND:  mem_store_data_o = load_data_q & rs2_val_q;
        AMO_OR:   mem_store_data_o = load_data_q | rs2_val_q;
        AMO_MIN:  mem_store_data_o = ($signed(load_data_q) < $signed(rs2_val_q)) ? load_data_q : rs2_val_q;
        AMO_MAX:  mem_store_data_o = ($signed(load_data_q) > $signed(rs2_val_q)) ? load_data_q : rs2_val_q;
        AMO_MINU: mem_store_data_o = (load_data_q < rs2_val_q) ? load_data_q : rs2_val_q;
        AMO_MAXU: mem_store_data_o = (load_data_q > rs2_val_q) ? load_data_q : rs2_val_q;
        default:  mem_store_data_o = load_data_q;
    endcase
end

// State machine
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= StIdle;
    else         state_q <= state_d;
end

always_comb begin
    unique case (state_q)
        StIdle:
            state_d = (amo_op_i != AMO_NONE) ? StLoad : StIdle;
        StLoad:
            state_d = mem_wait_i ? StLoad :
                      mem_err_i  ? StIdle :
                                   StStore;
        StStore:
            state_d = mem_wait_i ? StStore : StIdle;
        default: state_d = StIdle;
    endcase
end

// Output decode
always_comb begin
    unique case (state_q)
        StIdle:  mem_rw_o = (amo_op_i != AMO_NONE) ? RW_READ : RW_IDLE;
        StLoad:  mem_rw_o = RW_READ;
        StStore: mem_rw_o = RW_WRITE;
        default: mem_rw_o = RW_IDLE;
    endcase
end

endmodule

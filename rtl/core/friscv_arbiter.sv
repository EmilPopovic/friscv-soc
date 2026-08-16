// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

module friscv_arbiter import friscv_pkg::*; (
    input  logic       clk_i,
    input  logic       rst_ni,

    // Instruction Memory Interface
    input  addr_t      inst_addr_i,
    output data_t      inst_data_o,
    input  logic       inst_en_i,
    output logic       inst_wait_o,
    output logic       inst_err_o,

    // Data Memory Interface
    input  addr_t      data_addr_i,
    input  mem_width_e data_size_i,
    input  data_t      data_wdata_i,
    output data_t      data_rdata_o,
    input  logic       data_en_i,
    input  logic       data_wr_i,
    output logic       data_wait_o,
    input  amo_op_e    amo_op_i,
    output logic       data_err_o,

    // External Interface
    output addr_t      mem_addr_o,
    output mem_width_e mem_size_o,
    output data_t      mem_wdata_o,
    input  data_t      mem_rdata_i,
    output rw_cmd_e    mem_rw_o,
    input  logic       mem_wait_i,
    input  logic       mem_err_i,
    output amo_op_e    amo_op_o,

    // Status to the MMU
    output logic       grant_start_o,
    output logic       grant_start_inst_o,
    output logic       grant_held_o
);

// StIdle     : bus free, a request present on the core inputs is issued
//              combinationally in this same cycle.
// StHoldInst : an instruction fetch was issued and the memory asserted wait;
//              the request is frozen in r_inst_addr and re-driven until done.
// StHoldData : same for a data access.
typedef enum logic [1:0] {
    StIdle,
    StHoldInst,
    StHoldData
} state_e;

state_e state_q, state_d;
logic   data_priority_q;

addr_t      inst_addr_q;
addr_t      data_addr_q;
mem_width_e data_size_q;
data_t      data_wdata_q;
logic       data_wr_q;
amo_op_e    data_amo_q;

// ============================================================
// Issue selection
// ===========================================================
logic take_inst, take_data, take_any;

always_comb begin
    take_inst = 1'b0;
    take_data = 1'b0;
    if (state_q == StIdle) begin
        if (inst_en_i && data_en_i) begin
            take_inst = !data_priority_q;
            take_data =  data_priority_q;
        end else begin
            take_inst = inst_en_i;
            take_data = data_en_i;
        end
    end
end

assign take_any = take_inst | take_data;

// A transaction is on the bus this cycle if it is being issued now, or held
logic busy_inst, busy_data, busy;
assign busy_inst = take_inst | (state_q == StHoldInst);
assign busy_data = take_data | (state_q == StHoldData);
assign busy      = busy_inst | busy_data;

// Transaction retires this cycle
logic done;
assign done = busy & !mem_wait_i;

// Must park in a HOLD state, issued this cycle but the memory did not complete
logic park;
assign park = take_any & mem_wait_i;

// ============================================================
// Next state
// ============================================================
always_comb begin
    state_d = state_q;
    case (state_q)
        StIdle:     if (park) state_d = take_inst ? StHoldInst : StHoldData;
        StHoldInst,
        StHoldData: if (!mem_wait_i) state_d = StIdle;
        default:    state_d = StIdle;
    endcase
end

// ============================================================
// Sequentials == St
// ============================================================

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= StIdle;
    else         state_q <= state_d;
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        data_priority_q <= 1'b0;
        inst_addr_q     <= '0;
        data_addr_q     <= '0;
        data_size_q     <= WIDTH_I32;
        data_wdata_q    <= '0;
        data_wr_q       <= 1'b0;
        data_amo_q      <= AMO_NONE;
    end else begin
        // Freeze the request if it is going to be held
        if (park && take_inst) begin
            inst_addr_q  <= inst_addr_i;
        end
        if (park && take_data) begin
            data_addr_q  <= data_addr_i;
            data_size_q  <= data_size_i;
            data_wdata_q <= data_wdata_i;
            data_wr_q    <= data_wr_i;
            data_amo_q   <= amo_op_i;
        end
        // Rotate priority on completion
        if (done) begin
            data_priority_q <= busy_inst;
        end
    end
end

// ============================================================
// Output
// ============================================================
always_comb begin
    mem_addr_o  = '0;
    mem_size_o  = WIDTH_I32;
    mem_wdata_o = '0;
    mem_rw_o    = RW_IDLE;
    amo_op_o    = AMO_NONE;
    inst_wait_o = 1'b0;
    data_wait_o = 1'b0;
    inst_err_o  = 1'b0;
    data_err_o  = 1'b0;

    if (busy_inst) begin
        mem_addr_o  = take_inst ? inst_addr_i : inst_addr_q;
        mem_size_o  = WIDTH_I32;
        mem_rw_o    = RW_READ;

        inst_wait_o = mem_wait_i;
        inst_err_o  = mem_err_i;

        if (data_en_i) data_wait_o = 1'b1;   // data is queued

    end else if (busy_data) begin
        mem_addr_o  = take_data ? data_addr_i  : data_addr_q;
        mem_size_o  = take_data ? data_size_i  : data_size_q;
        mem_wdata_o = take_data ? data_wdata_i : data_wdata_q;
        mem_rw_o    = (take_data ? data_wr_i : data_wr_q) ? RW_WRITE : RW_READ;
        amo_op_o    = take_data ? amo_op_i     : data_amo_q;

        data_wait_o = mem_wait_i;
        data_err_o  = mem_err_i;

        if (inst_en_i) inst_wait_o = 1'b1;   // fetch is queued

    end else begin
        if (inst_en_i) inst_wait_o = 1'b1;
        if (data_en_i) data_wait_o = 1'b1;
    end
end

assign inst_data_o  = mem_rdata_i;
assign data_rdata_o = mem_rdata_i;

assign grant_start_o      = take_any;
assign grant_start_inst_o = take_inst;
assign grant_held_o       = (state_q != StIdle);

endmodule

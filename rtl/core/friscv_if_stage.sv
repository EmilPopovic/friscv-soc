// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the IF stage of the FRISC-V pipeline. It is responsible for:
 * - Maintaining the PC register and generating the next PC value
 * - Issuing instruction fetches to the instruction memory
 * - Taking redirects (jumps, traps, mret/sret) and flushing in-flight fetches
 */

module friscv_if_stage
    import friscv_pkg::*;
#(
    parameter int unsigned ResetVec = 32'h8000_0000
) (
    input  logic  clk_i,
    input  logic  rst_ni,

    // Stage control signals
    input  logic  flush_i,
    input  logic  stall_i,
    input  logic  wait_i,
    input  logic  jump_ok_i,
    input  addr_t jump_target_i,

    // Outputs to ID stage
    output addr_t pc_o,
    output addr_t next_pc_o,
    output inst_t ir_o,
    output logic  discard_o,

    // Instruction memory interface
    output addr_t mem_addr_o,
    input  inst_t mem_data_i,
    output logic  mem_en_o,
    
    // Interrupts
    input  logic  trap_i, 
    input  logic  ret_i,      
    input  addr_t tvec_i,    
    input  addr_t epc_i
);

addr_t pc_q;
inst_t ir_q;
logic  fetch_active_q;
logic  flush_pending_q;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        pc_q            <= ResetVec;
        fetch_active_q  <= 1'b1;
        ir_q            <= NOP;
        flush_pending_q <= 1'b0;
    end else begin
        if (flush_i || jump_ok_i || trap_i || ret_i) begin
            if (ret_i)          pc_q <= epc_i;
            else if (trap_i)    pc_q <= tvec_i;
            else if (jump_ok_i) pc_q <= jump_target_i;
            fetch_active_q  <= 1'b1;
            ir_q            <= NOP;
            flush_pending_q <= fetch_active_q && wait_i;
        end else if (flush_pending_q && !wait_i) begin
            fetch_active_q  <= 1'b1;
            flush_pending_q <= 1'b0;
        end else if (!stall_i) begin
            pc_q           <= next_pc_o;
            fetch_active_q <= 1'b1;
        end else if (fetch_active_q && !wait_i) begin
            ir_q           <= mem_data_i;
            fetch_active_q <= 1'b0;
        end
    end
end

assign discard_o  = flush_pending_q;
assign pc_o       = pc_q;
assign next_pc_o  = pc_q + 4;
assign mem_addr_o = pc_q;
assign mem_en_o   = fetch_active_q;

always_comb begin
    if (flush_pending_q)     ir_o = NOP;
    else if (fetch_active_q) ir_o = wait_i ? NOP : mem_data_i;
    else                     ir_o = ir_q;
end

endmodule

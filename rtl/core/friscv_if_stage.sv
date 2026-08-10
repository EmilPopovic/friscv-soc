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

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_if_stage import friscv_mem_pkg::*; #(
    parameter int unsigned RESET_VEC = 32'h8000_0000
) (
    input  logic  clk_in,
    input  logic  rst_n_in,

    // Stage control signals
    input  logic  flush_in,
    input  logic  stage_stall_in,
    input  logic  i_mem_wait_in,
    input  logic  jump_ok_in,
    input  addr_t jump_target_in,

    // Outputs to ID stage
    output addr_t pc_out,
    output addr_t pc_plus_4_out,
    output inst_t ir_out,

    // Instruction memory interface
    output addr_t i_mem_addr_out,
    input  inst_t i_mem_data_in,
    output logic  i_mem_en_out,
    
    // Interrupts
    input  logic  trap_in, 
    input  logic  ret_in,      
    input  addr_t tvec_in,    
    input  addr_t epc_in
);

addr_t pc_reg;
inst_t ir_buff;
logic  r_fetch_active;
// Set when a redirect (interrupt/jump/mret/flush) fires while a fetch is in-flight.
// The in-flight AXI response will arrive for the old address,
// we must discard it and re-issue the fetch for the redirect target.
logic  r_flush_pending;

always_ff @(posedge clk_in) begin
    if (!rst_n_in) begin
        pc_reg          <= RESET_VEC;
        r_fetch_active  <= 1'b1;
        ir_buff         <= NOP;
        r_flush_pending <= 1'b0;
    end else begin
        if (flush_in || jump_ok_in || trap_in || ret_in) begin
            if (ret_in) begin
                pc_reg <= epc_in;
            end else if (trap_in) begin
                pc_reg <= tvec_in;
            end else if (jump_ok_in) begin
                pc_reg <= jump_target_in;
            end else begin
                pc_reg <= RESET_VEC;
            end
            r_fetch_active  <= 1'b1;
            ir_buff         <= NOP;
            r_flush_pending <= r_fetch_active && i_mem_wait_in;
        end else if (r_flush_pending && !i_mem_wait_in) begin
            // Stale AXI response arrived for the old address.
            // Discard it, hold pc_reg at the redirect target, restart fetch.
            r_fetch_active  <= 1'b1;
            r_flush_pending <= 1'b0;
        end else if (!stage_stall_in) begin
            pc_reg         <= pc_plus_4_out;
            r_fetch_active <= 1'b1;
        end else if (r_fetch_active && !i_mem_wait_in) begin
            r_fetch_active <= 1'b0;
            ir_buff        <= i_mem_data_in;
        end
    end
end

always_comb begin
    pc_out = pc_reg;
    pc_plus_4_out = pc_reg + 4;
    i_mem_addr_out = pc_reg;
    i_mem_en_out = r_fetch_active;

    if (r_flush_pending) begin
        // Suppress stale data from reaching the ID stage
        ir_out = NOP;
    end else if (r_fetch_active) begin
        if (i_mem_wait_in) begin
            ir_out = NOP;
        end else begin
            ir_out = i_mem_data_in;
        end
    end else begin
        ir_out = ir_buff;
    end
end

endmodule

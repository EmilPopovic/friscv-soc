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
 * This module implements the control logic for stalling and flushing the pipeline, and for redirecting the IF stage to jump/branch targets and exception handlers.
 * It takes as input the decoded instruction information and hazard signals from each stage, and generates the appropriate control signals.
 *
 * This module mainly controls interactions between multiple stages, where the context of the entire pipeline is needed.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_pipeline_control (
    // Control signals
    output logic      flush_if_out,
    output logic      flush_id_out,
    output logic      flush_ex_out,
    output logic      stall_if_out,
    output logic      stall_id_out,
    output logic      stall_ex_out,
    output logic      stall_mem_out,

    // IF stage
    output logic      jump_ok_out,
    output addr_t     jump_target_out,
    output logic      eff_ret_out,

    // ID stage
    input  reg_addr_t id_rs1_sel_in,
    input  reg_addr_t id_rs2_sel_in,
    input  logic      jal_ok_in,
    input  addr_t     jal_target_in,
    input  logic      id_csr_en_in,
    input  csr_addr_e id_csr_sel_in,

    // EX stage
    input  reg_addr_t ex_rd_sel_in,
    input  logic      branch_ok_in,
    input  addr_t     branch_target_in,
    input  logic      ex_csr_en_in,
    input  csr_addr_e ex_csr_sel_in,
    input  logic      ex_div_active_in,

    // MEM stage
    input  reg_addr_t mem_rd_sel_in,
    input  logic      mem_csr_en_in,
    input  csr_addr_e mem_csr_sel_in,

    // WB stage
    input  reg_addr_t wb_rd_sel_in,
    input  logic      wb_csr_en_in,
    input  csr_addr_e wb_csr_sel_in,
    input  logic      ex_instr_valid_in,
    input  logic      mem_instr_valid_in,
    input  logic      wb_instr_valid_in,

    // Older memory ops ahead of a return must retire before redirecting to epc
    input  logic      ex_mem_inflight_in,
    input  logic      mem_mem_inflight_in,

    // Memory wait signals
    input  logic      if_wait_in,
    input  logic      mem_wait_in,
    
    // Interrupts
    input logic       trap_in,
    input logic       trap_pending_in,
    input logic       ret_in,

    input logic       halt_in
);

logic reg_hazard, csr_hazard, ret_csr_hazard, ret_pipe_hazard;
logic serializing_csr_hazard;
logic counter_csr_hazard;
logic mem_stall, hazard_stall, trap_pending_stall;

function automatic logic is_serializing_csr(csr_addr_e csr_sel);
begin
    case (csr_sel)
        // satp changes the address translation context globally, so younger
        // instructions must wait for the committed update.
        CSR_MSTATUS,
        CSR_SSTATUS,
        CSR_MEDELEG,
        CSR_MIDELEG,
        CSR_SATP: is_serializing_csr = 1'b1;
        default:  is_serializing_csr = 1'b0;
    endcase
end
endfunction

function automatic logic is_counter_csr(csr_addr_e csr_sel);
begin
    case (csr_sel)
        CSR_CYCLE, CSR_CYCLEH,
        CSR_TIME, CSR_TIMEH,
        CSR_INSTRET, CSR_INSTRETH: is_counter_csr = 1'b1;
        default:                   is_counter_csr = 1'b0;
    endcase
end
endfunction

// Early JAL/JALR must be suppressed when
//  1) EX cannot capture the decoded instruction (mem_stall) or
//  2) JALR's rs1 has a data hazard with EX (hazard_stall)
logic effective_jal, effective_ret;

always_comb begin
    mem_stall = if_wait_in || mem_wait_in;
    
    // No forwarding: stall while any in-flight stage holds a matching rd
    reg_hazard = ((ex_rd_sel_in  != 0) && ((id_rs1_sel_in == ex_rd_sel_in)  || (id_rs2_sel_in == ex_rd_sel_in)))  ||
                 ((mem_rd_sel_in != 0) && ((id_rs1_sel_in == mem_rd_sel_in) || (id_rs2_sel_in == mem_rd_sel_in))) ||
                 ((wb_rd_sel_in  != 0) && ((id_rs1_sel_in == wb_rd_sel_in)  || (id_rs2_sel_in == wb_rd_sel_in)));

    // mret/sret implicitly consume architected CSR state; wait for older CSR writes
    ret_csr_hazard = ret_in && (ex_csr_en_in || mem_csr_en_in || wb_csr_en_in);

    // Returns must not redirect to epc while older data ops are still draining.
    ret_pipe_hazard = ret_in && (mem_wait_in || ex_mem_inflight_in || mem_mem_inflight_in);

    // Serialize only the narrow always-serializing CSR subset.
    // Trap-control CSRs are still ordered by the trap/return hazards.
    serializing_csr_hazard = (ex_csr_en_in  && is_serializing_csr(ex_csr_sel_in))  ||
                             (mem_csr_en_in && is_serializing_csr(mem_csr_sel_in)) ||
                             (wb_csr_en_in  && is_serializing_csr(wb_csr_sel_in));

    // Counter CSR operations must wait for valid instructions to commit
    counter_csr_hazard = id_csr_en_in && is_counter_csr(id_csr_sel_in) &&
                         (ex_instr_valid_in || mem_instr_valid_in || wb_instr_valid_in);

    // Stall while trap is pending
    csr_hazard = (id_csr_en_in && ex_csr_en_in  && (id_csr_sel_in == ex_csr_sel_in))  ||
                 (id_csr_en_in && mem_csr_en_in && (id_csr_sel_in == mem_csr_sel_in)) ||
                 (id_csr_en_in && wb_csr_en_in  && (id_csr_sel_in == wb_csr_sel_in))  ||
                 serializing_csr_hazard ||
                 counter_csr_hazard ||
                 ret_csr_hazard ||
                 ret_pipe_hazard;

    hazard_stall = reg_hazard || csr_hazard;
    trap_pending_stall = trap_pending_in;

    // Suppress mret redirect until the hazard clears so IF sees the committed mepc
    effective_ret = ret_in && !ret_csr_hazard && !ret_pipe_hazard;
    effective_jal = jal_ok_in && !mem_stall && !hazard_stall && !trap_pending_stall;

    stall_if_out  = mem_stall || hazard_stall || trap_pending_stall || ex_div_active_in || halt_in;
    stall_id_out  = mem_stall || hazard_stall || trap_pending_stall || ex_div_active_in || halt_in;
    stall_ex_out  = mem_stall || ex_div_active_in;
    stall_mem_out = mem_stall;

    // Flush only when trap committed
    flush_if_out = branch_ok_in || effective_jal || trap_in || effective_ret;
    flush_id_out = branch_ok_in || effective_jal || trap_in || effective_ret;
    flush_ex_out = ((hazard_stall || trap_pending_stall) && !mem_stall && !ex_div_active_in) || trap_in;

    jump_ok_out     = branch_ok_in || effective_jal;
    jump_target_out = (branch_ok_in) ? branch_target_in : jal_target_in;
    eff_ret_out     = effective_ret;
end

endmodule

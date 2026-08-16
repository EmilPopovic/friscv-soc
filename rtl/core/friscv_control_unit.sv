// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the control logic for stalling and flushing the pipeline, and for redirecting the IF stage to jump/branch targets and exception handlers.
 * It takes as input the decoded instruction information and hazard signals from each stage, and generates the appropriate control signals.
 *
 * This module mainly controls interactions between multiple stages, where the context of the entire pipeline is needed.
 */

module friscv_control_unit import friscv_pkg::*; (
    // Control signals
    output logic      flush_if_o,
    output logic      flush_id_o,
    output logic      flush_ex_o,
    output logic      stall_if_o,
    output logic      stall_id_o,
    output logic      stall_ex_o,
    output logic      stall_mem_o,

    // IF stage
    output logic      jump_ok_o,
    output addr_t     jump_target_o,
    output logic      eff_ret_o,

    // ID stage
    input  reg_addr_t id_rs1_sel_i,
    input  reg_addr_t id_rs2_sel_i,
    input  logic      jal_ok_i,
    input  addr_t     jal_target_i,
    input  logic      id_csr_en_i,
    input  csr_addr_e id_csr_sel_i,
    input  logic      id_csr_is_counter_i,

    // EX stage
    input  reg_addr_t ex_rd_sel_i,
    input  logic      branch_ok_i,
    input  addr_t     branch_target_i,
    input  logic      ex_csr_en_i,
    input  csr_addr_e ex_csr_sel_i,
    input  logic      ex_muldiv_active_i,
    input  logic      ex_csr_is_serializing_i,

    // MEM stage
    input  reg_addr_t mem_rd_sel_i,
    input  logic      mem_csr_en_i,
    input  csr_addr_e mem_csr_sel_i,
    input  logic      mem_csr_is_serializing_i,

    // WB stage
    input  reg_addr_t wb_rd_sel_i,
    input  logic      wb_csr_en_i,
    input  csr_addr_e wb_csr_sel_i,
    input  logic      ex_instr_valid_i,
    input  logic      mem_instr_valid_i,
    input  logic      wb_instr_valid_i,
    input  logic      wb_csr_is_serializing_i,

    // Older memory ops ahead of a return must retire before redirecting to epc
    input  logic      ex_mem_inflight_i,
    input  logic      mem_mem_inflight_i,

    // Memory wait signals
    input  logic      if_wait_i,
    input  logic      mem_wait_i,
    
    // Interrupts
    input logic       trap_i,
    input logic       trap_pending_i,
    input logic       ret_i,

    input logic       halt_i
);

logic reg_hazard, csr_hazard, ret_csr_hazard, ret_pipe_hazard;
logic serializing_csr_hazard;
logic counter_csr_hazard;
logic mem_stall, hazard_stall, trap_pending_stall;
logic id_stall;

logic effective_jal, effective_ret;

always_comb begin
    mem_stall = if_wait_i || mem_wait_i;
    
    // No forwarding: stall while any in-flight stage holds a matching rd
    reg_hazard = ((ex_rd_sel_i  != 0) && ((id_rs1_sel_i == ex_rd_sel_i)  || (id_rs2_sel_i == ex_rd_sel_i)))  ||
                 ((mem_rd_sel_i != 0) && ((id_rs1_sel_i == mem_rd_sel_i) || (id_rs2_sel_i == mem_rd_sel_i))) ||
                 ((wb_rd_sel_i  != 0) && ((id_rs1_sel_i == wb_rd_sel_i)  || (id_rs2_sel_i == wb_rd_sel_i)));

    // mret/sret implicitly consume architected CSR state; wait for older CSR writes
    ret_csr_hazard = ret_i && (ex_csr_en_i || mem_csr_en_i || wb_csr_en_i);

    // Returns must not redirect to epc while older data ops are still draining.
    ret_pipe_hazard = ret_i && (mem_wait_i || ex_mem_inflight_i || mem_mem_inflight_i);

    // Serialize only the narrow always-serializing CSR subset.
    // Trap-control CSRs are still ordered by the trap/return hazards.
    serializing_csr_hazard = (ex_csr_en_i  && ex_csr_is_serializing_i)  ||
                             (mem_csr_en_i && mem_csr_is_serializing_i) ||
                             (wb_csr_en_i  && wb_csr_is_serializing_i);

    // Counter CSR operations must wait for valid instructions to commit
    counter_csr_hazard = id_csr_en_i && id_csr_is_counter_i &&
                         (ex_instr_valid_i || mem_instr_valid_i || wb_instr_valid_i);

    // Stall while trap is pending
    csr_hazard = (id_csr_en_i && ex_csr_en_i  && (id_csr_sel_i == ex_csr_sel_i))  ||
                 (id_csr_en_i && mem_csr_en_i && (id_csr_sel_i == mem_csr_sel_i)) ||
                 (id_csr_en_i && wb_csr_en_i  && (id_csr_sel_i == wb_csr_sel_i))  ||
                 serializing_csr_hazard ||
                 counter_csr_hazard ||
                 ret_csr_hazard ||
                 ret_pipe_hazard;

    hazard_stall = reg_hazard || csr_hazard;
    trap_pending_stall = trap_pending_i;

    id_stall = mem_stall || hazard_stall || trap_pending_stall || ex_muldiv_active_i || halt_i;

    // Suppress mret redirect until the hazard clears so IF sees the committed mepc
    effective_ret = ret_i && !ret_csr_hazard && !ret_pipe_hazard && !id_stall;
    effective_jal = jal_ok_i && !id_stall;

    stall_if_o  = id_stall;
    stall_id_o  = id_stall;
    stall_ex_o  = mem_stall || ex_muldiv_active_i;
    stall_mem_o = mem_stall;

    // Flush only when trap committed
    flush_if_o = branch_ok_i || effective_jal || trap_i || effective_ret;
    flush_id_o = branch_ok_i || effective_jal || trap_i || effective_ret;
    flush_ex_o = ((hazard_stall || trap_pending_stall) && !mem_stall && !ex_muldiv_active_i) || trap_i;

    jump_ok_o     = branch_ok_i || effective_jal;
    jump_target_o = (branch_ok_i) ? branch_target_i : jal_target_i;
    eff_ret_o     = effective_ret;
end

endmodule

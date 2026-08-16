// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the Instruction Decode (ID) stage of the FRISC-V pipeline. It is responsible for:
 * - Capturing inputs from the IF stage and buffering them for the EX stage
 * - Reading the register file for source operands (friscv_id_regfile.sv)
 * - Decoding the instruction and generating control signals for the EX stage (friscv_id_decoder.sv)
 * - Serving CSR reads and retiring CSR writes through the CSR file (friscv_csr_file.sv)
 * - Committing traps and interrupts through the trap controller (friscv_trap_controller.sv)
 * - Interfacing with the pipeline control logic for stalling and flushing
 *
 * The ID stage is the module that commits traps, meaning it determines when a trap should be taken, and from what source.
 * It then confirms to the trapping stage that its trap is being handled (through x_trap_commit_out).
 * Trap detection, prioritization and hart state live in friscv_trap_controller; architectural CSR state lives in
 * friscv_csr_file, with the trap controller commanding CSR trap captures through a dedicated commit interface.
 */

module friscv_id_stage
    import friscv_pkg::*;
#(
    parameter int unsigned HartId = 0,

    // Debug module parameters
    parameter int unsigned DmBase       = 32'h0000_0000,
    parameter int unsigned DmHaltOffset = 32'h800,
    parameter int unsigned DmExcOffset  = 32'h810,

    // Extension selection
    parameter bit EnableIsaE = 0,
    parameter bit EnableIsaM = 1,
    parameter bit EnableIsaA = 1,

    // Memory protection
    parameter bit          EnforcePmp = 0,
    parameter int unsigned PmpEntries = 8,
    parameter int unsigned PmpUsable  = 8,

    // If enabled, entering an EBREAK instruction will halt the core until reset
    parameter bit HaltOnEnterEbreak   = 0,
    // If enabled, the first MRET or SRET after entering an EBREAK handler will halt the core until reset
    parameter bit HaltOnRetFromEbreak = 0
) (
    input  logic      clk_i,
    input  logic      rst_ni,
    output logic      halt_o,
    input  logic      dbg_req_i,

    input  logic      branch_ok_i,

    // Interrupt pending inputs
    input  logic      msip_i,
    input  logic      mtip_i,
    input  logic      meip_i,
    input  logic      seip_i,

    // CLINT time
    input  mtime_t    mtime_i,

    // Instruction fetch page fault
    input  logic      inst_fault_i,
    input  addr_t     fault_addr_i,
    input  logic      inst_err_i,
    input  logic      inst_pmp_fault_i,

    // Data memory page fault
    input  mem_trap_e mem_trap_i,
    input  addr_t     mem_trap_pc_i,
    input  addr_t     mem_trap_va_i,
    input  mode_e     mem_trap_mode_i,
    output logic      mem_trap_commit_o,

    // EX stage trap
    input  ex_trap_e  ex_trap_i,
    input  addr_t     ex_trap_pc_i,
    input  addr_t     ex_trap_va_i,
    input  mode_e     ex_trap_mode_i,
    output logic      ex_trap_commit_o,

    // Stage control signals
    input  logic      flush_i,
    input  logic      stall_i,

    // Outputs to control logic
    output reg_addr_t rs1_sel_o,
    output reg_addr_t rs2_sel_o,
    output reg_addr_t rd_sel_o,

    output logic      jal_ok_o,
    output addr_t     jal_target_o,
    output logic      csr_is_counter_o,

    // Inputs from IF stage
    input  addr_t     pc_i,
    input  addr_t     next_pc_i,
    input  inst_t     ir_i,

    // Outputs to EX stage
    output addr_t     pc_o,
    output addr_t     next_pc_o,
    output data_t     rs1_o,
    output data_t     rs2_o,
    output data_t     imm_o,
    output data_t     csr_o,
    output instr_ex_t instr_o,

    // Inputs from older stages for state visibility
    input  reg_addr_t ex_rd_sel_i,
    input  reg_addr_t mem_rd_sel_i,
    input  logic      ex_muldiv_active_i,

    // Inputs from WB stage
    input  reg_addr_t rd_sel_i,
    input  data_t     rd_i,
    input  csr_addr_e csr_sel_i,
    input  data_t     csr_data_i,
    input  logic      csr_en_i,
    input  logic      instr_ret_i,

    // CSR write-in-flight visibility
    input  logic      ex_csr_en_i,
    input  logic      mem_csr_en_i,
    input  logic      wb_csr_en_i,
    input  logic      ex_mem_inflight_i,
    input  logic      mem_mem_inflight_i,

    // Outputs and inputs for handling interrupts
    output addr_t     tvec_o,          // Resolved mtvec or stvec
    output addr_t     epc_o,           // Resolved mepc or sepc
    output logic      trap_o,
    output logic      trap_pending_o,
    output logic      ret_o,           // Active for both mret and sret
    input  logic      ret_commit_i,

    // Outputs to MMU
    output satp_t     satp_o,
    output logic      sum_o,
    output logic      mxr_o,
    output mode_e     mode_o,
    output mode_e     data_mode_o,
    output pmp_entry_t [PmpEntries-1:0] pmp_table_o
);

instr_op_t ir_q;
addr_t     pc_in_q;
addr_t     next_pc_q;
logic      instr_valid_q;
imm_e      imm_sel;
logic      inst_fault_q;
addr_t     fault_addr_q;
logic      inst_err_q;
logic      inst_pmp_fault_q;
mode_e     pc_mode_q;

assign pc_o      = pc_in_q;
assign next_pc_o = next_pc_q;

// Current privilege mode and debug mode of the hart, owned by the trap controller.
mode_e current_mode;
logic  debug_mode_active;

assign mode_o = current_mode;

// JALR's jump base is rs1, so it reuses the rs1 read port instead of a
// dedicated third read port.
addr_t jump_base;
assign jump_base = rs1_o;

logic regfile_wr_en;
assign regfile_wr_en = (rd_sel_i != '0) && instr_ret_i;

localparam int unsigned RegisterNum = EnableIsaE ? 16 : 32;

friscv_regfile #(
    .RegisterNum ( RegisterNum )
) i_regfile (
    .clk_i,
    .rs1_sel_i ( rs1_sel_o     ),
    .rs2_sel_i ( rs2_sel_o     ),
    .wen_i     ( regfile_wr_en ),
    .rd_sel_i,
    .rd_i,
    .rs1_o,
    .rs2_o
);

///////////////////
// Input Capture //
///////////////////

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        ir_q             <= NOP;
        pc_in_q          <= '0;
        next_pc_q        <= '0;
        instr_valid_q    <= 1'b0;
        inst_fault_q     <= 1'b0;
        fault_addr_q     <= '0;
        inst_err_q       <= 1'b0;
        inst_pmp_fault_q <= 1'b0;
        pc_mode_q        <= M_MODE;
    end else begin
        if (flush_i) begin
            ir_q             <= NOP;
            pc_in_q          <= '0;
            next_pc_q        <= '0;
            instr_valid_q    <= 1'b0;
            inst_fault_q     <= 1'b0;
            fault_addr_q     <= '0;
            inst_err_q       <= 1'b0;
            inst_pmp_fault_q <= 1'b0;
            pc_mode_q        <= M_MODE;
        end else if (!stall_i) begin
            ir_q             <= ir_i;
            pc_in_q          <= pc_i;
            next_pc_q        <= next_pc_i;
            instr_valid_q    <= 1'b1;
            inst_fault_q     <= inst_fault_i;
            fault_addr_q     <= fault_addr_i;
            inst_err_q       <= inst_err_i;
            inst_pmp_fault_q <= inst_pmp_fault_i;
            pc_mode_q        <= current_mode;
        end
    end
end

//////////////////////////////////
// Control and Status Registers //
//////////////////////////////////

csr_addr_e selected_csr;
assign selected_csr = csr_addr_e'(ir_q.b[31:20]);

// CSR state consumed by the trap controller and decoder
mstatus_t mstatus;
addr_t    mtvec, stvec;
addr_t    dpc, sepc, mepc;
data_t    medeleg, mideleg, mie;
logic     ssip, stip_eff, seip_eff;
dcsr_t    dcsr;
data_t    mcounteren, scounteren;
logic     csr_not_impl;

// Trap commit commands from the trap controller to the CSR file
logic       trap_csr_en;
logic       trap_to_debug;
logic       trap_to_s;
addr_t      trap_epc;
data_t      trap_cause;
data_t      trap_tval;
mode_e      trap_mode;
logic [2:0] dcsr_cause;
logic       mret_commit, sret_commit, dret_commit;

friscv_csr_file #(
    .HartId     ( HartId     ),
    .EnforcePmp ( EnforcePmp ),
    .PmpEntries ( PmpEntries ),
    .PmpUsable  ( PmpUsable  ),
    .EnableIsaE ( EnableIsaE ),
    .EnableIsaM ( EnableIsaM ),
    .EnableIsaA ( EnableIsaA )
) i_csr_file (
    .clk_i,
    .rst_ni,
    .mode_i          ( current_mode      ),
    .debug_mode_i    ( debug_mode_active ),
    .selected_csr_i  ( selected_csr      ),
    .csr_o,
    .csr_not_impl_o  ( csr_not_impl      ),
    .csr_sel_i,
    .csr_en_i,
    .csr_data_i,
    .instr_ret_i,
    .trap_i          ( trap_o            ),
    .trap_csr_en_i   ( trap_csr_en       ),
    .trap_to_debug_i ( trap_to_debug     ),
    .trap_to_s_i     ( trap_to_s         ),
    .trap_epc_i      ( trap_epc          ),
    .trap_cause_i    ( trap_cause        ),
    .trap_tval_i     ( trap_tval         ),
    .trap_mode_i     ( trap_mode         ),
    .dcsr_cause_i    ( dcsr_cause        ),
    .mret_commit_i   ( mret_commit       ),
    .sret_commit_i   ( sret_commit       ),
    .dret_commit_i   ( dret_commit       ),
    .mstatus_o       ( mstatus           ),
    .mtvec_o         ( mtvec             ),
    .stvec_o         ( stvec             ),
    .medeleg_o       ( medeleg           ),
    .mideleg_o       ( mideleg           ),
    .mie_o           ( mie               ),
    .dcsr_o          ( dcsr              ),
    .dpc_o           ( dpc               ),
    .sepc_o          ( sepc              ),
    .mepc_o          ( mepc              ),
    .ssip_o          ( ssip              ),
    .stip_eff_o      ( stip_eff          ),
    .seip_eff_o      ( seip_eff          ),
    .mcounteren_o    ( mcounteren        ),
    .scounteren_o    ( scounteren        ),
    .msip_i,
    .mtip_i,
    .meip_i,
    .seip_i,
    .mtime_i,
    .pmp_table_o,
    .satp_o,
    .sum_o,
    .mxr_o,
    .data_mode_o
);

/////////////////////
// Trap controller //
/////////////////////

logic  ecall_active, ebreak_active, illegal_inst;
logic  target_misaligned;
addr_t misaligned_target;

friscv_trap_controller #(
    .DmBase              ( DmBase              ),
    .DmHaltOffset        ( DmHaltOffset        ),
    .DmExcOffset         ( DmExcOffset         ),
    .HaltOnEnterEbreak   ( HaltOnEnterEbreak   ),
    .HaltOnRetFromEbreak ( HaltOnRetFromEbreak )
) i_trap_controller (
    .clk_i,
    .rst_ni,
    .halt_o,
    .dbg_req_i,
    .branch_ok_i,
    .msip_i,
    .mtip_i,
    .meip_i,
    .flush_i,
    .stall_i,
    .ir_i                ( ir_q               ),
    .pc_i                ( pc_in_q            ),
    .instr_valid_i       ( instr_valid_q      ),
    .pc_mode_i           ( pc_mode_q          ),
    .inst_fault_q_i      ( inst_fault_q       ),
    .fault_addr_q_i      ( fault_addr_q       ),
    .inst_err_q_i        ( inst_err_q         ),
    .inst_pmp_fault_q_i  ( inst_pmp_fault_q   ),
    .inst_fault_i,
    .inst_err_i,
    .inst_pmp_fault_i,
    .illegal_inst_i      ( illegal_inst       ),
    .ecall_active_i      ( ecall_active       ),
    .ebreak_active_i     ( ebreak_active      ),
    .target_misaligned_i ( target_misaligned  ),
    .misaligned_target_i ( misaligned_target  ),
    .mret_en_i           ( instr_o.mret_en    ),
    .sret_en_i           ( instr_o.sret_en    ),
    .ex_trap_i,
    .ex_trap_pc_i,
    .ex_trap_va_i,
    .ex_trap_mode_i,
    .ex_trap_commit_o,
    .mem_trap_i,
    .mem_trap_pc_i,
    .mem_trap_va_i,
    .mem_trap_mode_i,
    .mem_trap_commit_o,
    .ex_rd_sel_i,
    .mem_rd_sel_i,
    .wb_rd_sel_i         ( rd_sel_i           ),
    .ex_muldiv_active_i,
    .ex_csr_en_i,
    .mem_csr_en_i,
    .wb_csr_en_i,
    .ex_mem_inflight_i,
    .mem_mem_inflight_i,
    .mstatus_i           ( mstatus            ),
    .mtvec_i             ( mtvec              ),
    .stvec_i             ( stvec              ),
    .medeleg_i           ( medeleg            ),
    .mideleg_i           ( mideleg            ),
    .mie_i               ( mie                ),
    .dcsr_i              ( dcsr               ),
    .dpc_i               ( dpc                ),
    .sepc_i              ( sepc               ),
    .mepc_i              ( mepc               ),
    .ssip_i              ( ssip               ),
    .stip_eff_i          ( stip_eff           ),
    .seip_eff_i          ( seip_eff           ),
    .tvec_o,
    .epc_o,
    .trap_o,
    .trap_pending_o,
    .ret_o,
    .ret_commit_i,
    .mode_o              ( current_mode       ),
    .debug_mode_o        ( debug_mode_active  ),
    .trap_csr_en_o       ( trap_csr_en        ),
    .trap_to_debug_o     ( trap_to_debug      ),
    .trap_to_s_o         ( trap_to_s          ),
    .trap_epc_o          ( trap_epc           ),
    .trap_cause_o        ( trap_cause         ),
    .trap_tval_o         ( trap_tval          ),
    .trap_mode_o         ( trap_mode          ),
    .dcsr_cause_o        ( dcsr_cause         ),
    .mret_commit_o       ( mret_commit        ),
    .sret_commit_o       ( sret_commit        ),
    .dret_commit_o       ( dret_commit        )
);

//////////////////////////
// Immediate generation //
//////////////////////////

always_comb begin
    unique case (imm_sel)
        I_TYPE:  imm_o = {{21{ir_q.b[31]}}, ir_q.b[30:20]};
        I2_TYPE: imm_o = {27'h0, ir_q.b[24:20]};
        S_TYPE:  imm_o = {{21{ir_q.b[31]}}, ir_q.b[30:25], ir_q.b[11:7]};
        B_TYPE:  imm_o = {{20{ir_q.b[31]}}, ir_q.b[7], ir_q.b[30:25], ir_q.b[11:8], 1'b0};
        U_TYPE:  imm_o = {ir_q.b[31], ir_q.b[30:12], 12'b0};
        J_TYPE:  imm_o = {{12{ir_q.b[31]}}, ir_q.b[19:12], ir_q.b[20], ir_q.b[30:21], 1'b0};
        ZERO:    imm_o = 32'h0;
        NEXT_PC: imm_o = next_pc_q;
        default: imm_o = 32'h0;
    endcase
end

////////////////////
// Early JAL/JALR //
////////////////////

addr_t jal_target;
assign jal_target_o = jal_ok_o ? jal_target : '0;

// Compute target_misaligned independently of trap_out to avoid a combinatorial loop.
// target_misaligned is only active when the instruction is a JAL/JALR and the target address is misaligned.
// misaligned_tartget is the computed target address for JAL/JALR, used to update tval, 0 otherwise.
always_comb begin
    if (ir_q.r.opcode == JALR) begin
        automatic addr_t jalr_base = (rd_sel_i != 0 && ir_q.r.rs1 == rd_sel_i) ? rd_i : jump_base;
        automatic data_t jalr_imm = {{21{ir_q.b[31]}}, ir_q.b[30:20]};
        automatic addr_t target = (jalr_base + jalr_imm) & ~ 32'd1;
        target_misaligned = target[1] && instr_valid_q;
        misaligned_target = target;
    end else if (ir_q.r.opcode == JAL) begin
        automatic data_t jal_imm = {{12{ir_q.b[31]}}, ir_q.b[19:12], ir_q.b[20], ir_q.b[30:21], 1'b0};
        automatic addr_t target = pc_in_q + jal_imm;
        target_misaligned = target[1] && instr_valid_q;
        misaligned_target = target;
    end else begin
        target_misaligned = 1'b0;
        misaligned_target = '0;
    end
end

// Compute the final target of a JAL/JALR.
// This is separate from the target_misaligned logic to avoid a combinatorial loop in trap detection.
always_comb begin
    if (!trap_o) begin
        automatic addr_t jal_target_base = '0;
        automatic data_t jal_imm = '0;
        if (ir_q.r.opcode == JALR) begin
            jal_ok_o        = !target_misaligned;
            jal_target_base = (rd_sel_i != 0 && ir_q.r.rs1 == rd_sel_i) ? rd_i : jump_base;
            jal_imm         = {{21{ir_q.b[31]}}, ir_q.b[30:20]};  // I-type immediate
            jal_target      = (jal_target_base + jal_imm) & ~32'h1;
        end else if (ir_q.r.opcode == JAL) begin
            jal_ok_o = !target_misaligned;
            jal_imm  = {{12{ir_q.b[31]}}, ir_q.b[19:12], ir_q.b[20], ir_q.b[30:21], 1'b0};  // J-type immediate
            jal_target = pc_in_q + jal_imm;
        end else begin
            jal_ok_o   = 1'b0;
            jal_target = '0;
        end
    end else begin
        jal_ok_o   = 1'b0;
        jal_target = '0;
    end
end

//////////////////////////
// Instruction Decoding //
//////////////////////////

assign csr_is_counter_o = instr_o.csr_is_counter;

friscv_decoder #(
    .EnableIsaE ( EnableIsaE ),
    .EnableIsaA ( EnableIsaA ),
    .EnableIsaM ( EnableIsaM )
) i_decoder (
    .ir_i                  ( ir_q              ),
    .mode_i                ( current_mode      ),
    .dbg_active_i          ( debug_mode_active ),
    .tvm_i                 ( mstatus.tvm       ),
    .csr_not_implemented_i ( csr_not_impl      ),
    .mcounteren_i          ( mcounteren        ),
    .scounteren_i          ( scounteren        ),
    .instr_valid_i         ( instr_valid_q     ),
    .instr_o,
    .rs1_sel_o,
    .rs2_sel_o,
    .rd_sel_o,
    .imm_sel_o             ( imm_sel           ),
    .illegal_inst_o        ( illegal_inst      ),
    .ecall_active_o        ( ecall_active      ),
    .ebreak_active_o       ( ebreak_active     )
);

endmodule

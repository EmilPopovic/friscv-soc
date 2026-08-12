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

module friscv_id_stage import friscv_pkg::*, friscv_mem_pkg::*; #(
    parameter int unsigned HART_ID = 0,
    parameter int unsigned DM_BASE = 32'h0000_0000,
    parameter int unsigned DM_HALT_OFFSET = 32'h800,
    parameter int unsigned DM_EXC_OFFSET  = 32'h810,

    // Extension selection
    parameter logic ENABLE_MUL = 1,
    parameter logic ENABLE_DIV = 1,
    parameter logic ENABLE_EXTENSION_A = 1,

    // Memory protection
    parameter logic ENFORCE_PMP = 0,
    parameter int   PMP_ENTRIES = 8,
    parameter int   PMP_USABLE  = 8,

    // If enabled, entering an EBREAK instruction will halt the core until reset
    parameter logic ENABLE_HALT_ON_ENTER_EBREAK = 0,
    // If enabled, the first MRET or SRET after entering an EBREAK handler will halt the core until reset
    parameter logic ENABLE_HALT_ON_RET_FROM_EBREAK = 0
) (
    input  logic      clk_in,
    input  logic      rst_n_in,
    output logic      halt_out,
    input  logic      dbg_req_in,

    input  logic      branch_ok_in,

    // Interrupt pending inputs
    input  logic      msip_in,
    input  logic      mtip_in,
    input  logic      meip_in,
    input  logic      seip_in,

    // CLINT time
    input  mtime_t    mtime_in,

    // Instruction fetch page fault
    input  logic      inst_fault_in,
    input  addr_t     fault_addr_in,
    input  logic      inst_err_in,
    input  logic      inst_pmp_fault_in,

    // Data memory page fault
    input  mem_trap_e mem_trap_in,
    input  addr_t     mem_trap_pc_in,
    input  addr_t     mem_trap_va_in,
    input  mode_e     mem_trap_mode_in,
    output logic      mem_trap_commit_out,

    // EX stage trap
    input  ex_trap_e  ex_trap_in,
    input  addr_t     ex_trap_pc_in,
    input  addr_t     ex_trap_va_in,
    input  mode_e     ex_trap_mode_in,
    output logic      ex_trap_commit_out,

    // Stage control signals
    input  logic      flush_in,
    input  logic      stage_stall_in,

    // Outputs to control logic
    output reg_addr_t rs1_sel_out,
    output reg_addr_t rs2_sel_out,
    output reg_addr_t rd_sel_out,

    output logic      jal_ok_out,
    output addr_t     jal_target_out,

    // Inputs from IF stage
    input  addr_t     pc_in,
    input  addr_t     pc_plus_4_in,
    input  inst_t     ir_in,

    // Outputs to EX stage
    output addr_t     pc_out,
    output addr_t     pc_plus_4_out,
    output data_t     rs1_out,
    output data_t     rs2_out,
    output data_t     imm32_out,
    output data_t     csr_out,
    output instr_ex_t instr_ex_out,

    // Inputs from older stages for state visibility
    input  reg_addr_t ex_rd_sel_in,
    input  reg_addr_t mem_rd_sel_in,
    input  logic      ex_muldiv_active_in,

    // Inputs from WB stage
    input  reg_addr_t rd_sel_in,
    input  data_t     rd_data_in,
    input  csr_addr_e csr_sel_in,
    input  data_t     csr_data_in,
    input  logic      csr_en_in,
    input  logic      instr_ret_in,

    // CSR write-in-flight visibility
    input  logic      ex_csr_en_in,
    input  logic      mem_csr_en_in,
    input  logic      wb_csr_en_in,
    input  logic      ex_mem_inflight_in,
    input  logic      mem_mem_inflight_in,

    // Outputs and inputs for handling interrupts
    output addr_t     tvec_out,          // Resolved mtvec or stvec
    output addr_t     epc_out,           // Resolved mepc or sepc
    output logic      trap_out,
    output logic      trap_pending_out,
    output logic      ret_out,           // Active for both mret and sret
    input  logic      ret_commit_in,

    // Outputs to MMU
    output satp_t     satp_out,
    output logic      sum_out,
    output logic      mxr_out,
    output mode_e     mode_out,
    output mode_e     data_mode_out,
    output pmp_entry_t [PMP_ENTRIES-1:0] pmp_table_out
);

instr_op_t ir_buff;
addr_t     pc_in_buff;
addr_t     pc_plus_4_buff;
logic      instr_valid_buff;
imm_e      imm_sel;
logic      inst_fault_buff;
addr_t     fault_addr_buff;
logic      inst_err_buff;
logic      inst_pmp_fault_buff;
mode_e     pc_mode_buff;

assign pc_out = pc_in_buff;
assign pc_plus_4_out = pc_plus_4_buff;

// Current privilege mode and debug mode of the hart, owned by the trap controller.
mode_e current_mode;
logic  debug_mode_active;

assign mode_out = current_mode;

// JALR's jump base is rs1, so it reuses the rs1 read port instead of a
// dedicated third read port.
addr_t jump_base;
assign jump_base = rs1_out;

logic regfile_wr_en;
assign regfile_wr_en = (rd_sel_in != 0) && instr_ret_in;

friscv_id_regfile regfile (
    .clk_in           ( clk_in        ),
    .rs1_sel_in       ( rs1_sel_out   ),
    .rs2_sel_in       ( rs2_sel_out   ),
    .rd_sel_in        ( rd_sel_in     ),
    .rd_data_in       ( rd_data_in    ),
    .wr_en_in         ( regfile_wr_en ),
    .rs1_data_out     ( rs1_out       ),
    .rs2_data_out     ( rs2_out       )
);

// ============================================================
// Input capture
// ============================================================

always_ff @(posedge clk_in or negedge rst_n_in) begin
    if (!rst_n_in) begin
        ir_buff             <= NOP;
        pc_in_buff          <= '0;
        pc_plus_4_buff      <= '0;
        instr_valid_buff    <= 1'b0;
        inst_fault_buff     <= 1'b0;
        fault_addr_buff     <= '0;
        inst_err_buff       <= 1'b0;
        inst_pmp_fault_buff <= 1'b0;
        pc_mode_buff        <= M_MODE;
    end else begin
        if (flush_in) begin
            ir_buff             <= NOP;
            pc_in_buff          <= '0;
            pc_plus_4_buff      <= '0;
            instr_valid_buff    <= 1'b0;
            inst_fault_buff     <= 1'b0;
            fault_addr_buff     <= '0;
            inst_err_buff       <= 1'b0;
            inst_pmp_fault_buff <= 1'b0;
            pc_mode_buff        <= M_MODE;
        end else if (!stage_stall_in) begin
            ir_buff             <= ir_in;
            pc_in_buff          <= pc_in;
            pc_plus_4_buff      <= pc_plus_4_in;
            instr_valid_buff    <= 1'b1;
            inst_fault_buff     <= inst_fault_in;
            fault_addr_buff     <= fault_addr_in;
            inst_err_buff       <= inst_err_in;
            inst_pmp_fault_buff <= inst_pmp_fault_in;
            pc_mode_buff        <= current_mode;
        end
    end
end

// ============================================================
// Control and Status Registers
// ============================================================

csr_addr_e selected_csr;
assign selected_csr = csr_addr_e'(ir_buff.b[31:20]);

// CSR state consumed by the trap controller and decoder
mstatus_t mstatus;
addr_t    mtvec, stvec;
addr_t    dpc, sepc, mepc;
data_t    medeleg, mideleg, mie;
logic     ssip, stip_eff, seip_eff;
dcsr_t    dcsr;
data_t    mcounteren, scounteren;
logic     csr_not_implemented;

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
    .HART_ID            ( HART_ID            ),
    .ENFORCE_PMP        ( ENFORCE_PMP        ),
    .PMP_ENTRIES        ( PMP_ENTRIES        ),
    .PMP_USABLE         ( PMP_USABLE         ),
    .ENABLE_MUL         ( ENABLE_MUL         ),
    .ENABLE_DIV         ( ENABLE_DIV         ),
    .ENABLE_EXTENSION_A ( ENABLE_EXTENSION_A )
 ) friscv_csr_file (
    .clk_in              ( clk_in              ),
    .rst_n_in            ( rst_n_in            ),
    .mode_in             ( current_mode        ),
    .debug_mode_in       ( debug_mode_active   ),
    .selected_csr        ( selected_csr        ),
    .csr_out             ( csr_out             ),
    .csr_not_implemented ( csr_not_implemented ),
    .csr_sel_in          ( csr_sel_in          ),
    .csr_en_in           ( csr_en_in           ),
    .csr_data_in         ( csr_data_in         ),
    .instr_ret_in        ( instr_ret_in        ),
    .trap_in             ( trap_out            ),
    .trap_csr_en_in      ( trap_csr_en         ),
    .trap_to_debug_in    ( trap_to_debug       ),
    .trap_to_s_in        ( trap_to_s           ),
    .trap_epc_in         ( trap_epc            ),
    .trap_cause_in       ( trap_cause          ),
    .trap_tval_in        ( trap_tval           ),
    .trap_mode_in        ( trap_mode           ),
    .dcsr_cause_in       ( dcsr_cause          ),
    .mret_commit_in      ( mret_commit         ),
    .sret_commit_in      ( sret_commit         ),
    .dret_commit_in      ( dret_commit         ),
    .mstatus_out         ( mstatus             ),
    .mtvec_out           ( mtvec               ),
    .stvec_out           ( stvec               ),
    .medeleg_out         ( medeleg             ),
    .mideleg_out         ( mideleg             ),
    .mie_out             ( mie                 ),
    .dcsr_out            ( dcsr                ),
    .dpc_out             ( dpc                 ),
    .sepc_out            ( sepc                ),
    .mepc_out            ( mepc                ),
    .ssip_out            ( ssip                ),
    .stip_eff_out        ( stip_eff            ),
    .seip_eff_out        ( seip_eff            ),
    .msip_in             ( msip_in             ),
    .mtip_in             ( mtip_in             ),
    .meip_in             ( meip_in             ),
    .seip_in             ( seip_in             ),
    .mtime_in            ( mtime_in            ),
    .mcounteren_out      ( mcounteren          ),
    .scounteren_out      ( scounteren          ),
    .pmp_table_out       ( pmp_table_out       ),
    .satp_out            ( satp_out            ),
    .sum_out             ( sum_out             ),
    .mxr_out             ( mxr_out             ),
    .data_mode_out       ( data_mode_out       )
);

// ============================================================
// Trap controller
// ============================================================

logic  ecall_active, ebreak_active, illegal_inst;
logic  target_misaligned;
addr_t misaligned_target;

friscv_trap_controller #(
    .DM_BASE                        ( DM_BASE                        ),
    .DM_HALT_OFFSET                 ( DM_HALT_OFFSET                 ),
    .DM_EXC_OFFSET                  ( DM_EXC_OFFSET                  ),
    .ENABLE_HALT_ON_ENTER_EBREAK    ( ENABLE_HALT_ON_ENTER_EBREAK    ),
    .ENABLE_HALT_ON_RET_FROM_EBREAK ( ENABLE_HALT_ON_RET_FROM_EBREAK )
) friscv_trap_controller (
    .clk_in                 ( clk_in               ),
    .rst_n_in               ( rst_n_in             ),
    .halt_out               ( halt_out             ),
    .dbg_req_in             ( dbg_req_in           ),
    .branch_ok_in           ( branch_ok_in         ),
    .msip_in                ( msip_in              ),
    .mtip_in                ( mtip_in              ),
    .meip_in                ( meip_in              ),
    .flush_in               ( flush_in             ),
    .stage_stall_in         ( stage_stall_in       ),
    .ir_in                  ( ir_buff              ),
    .pc_in                  ( pc_in_buff           ),
    .instr_valid_in         ( instr_valid_buff     ),
    .pc_mode_in             ( pc_mode_buff         ),
    .inst_fault_buff_in     ( inst_fault_buff      ),
    .fault_addr_buff_in     ( fault_addr_buff      ),
    .inst_err_buff_in       ( inst_err_buff        ),
    .inst_pmp_fault_buff_in ( inst_pmp_fault_buff  ),
    .inst_fault_in          ( inst_fault_in        ),
    .inst_err_in            ( inst_err_in          ),
    .inst_pmp_fault_in      ( inst_pmp_fault_in    ),
    .illegal_inst_in        ( illegal_inst         ),
    .ecall_active_in        ( ecall_active         ),
    .ebreak_active_in       ( ebreak_active        ),
    .target_misaligned_in   ( target_misaligned    ),
    .misaligned_target_in   ( misaligned_target    ),
    .mret_en_in             ( instr_ex_out.mret_en ),
    .sret_en_in             ( instr_ex_out.sret_en ),
    .ex_trap_in             ( ex_trap_in           ),
    .ex_trap_pc_in          ( ex_trap_pc_in        ),
    .ex_trap_va_in          ( ex_trap_va_in        ),
    .ex_trap_mode_in        ( ex_trap_mode_in      ),
    .ex_trap_commit_out     ( ex_trap_commit_out   ),
    .mem_trap_in            ( mem_trap_in          ),
    .mem_trap_pc_in         ( mem_trap_pc_in       ),
    .mem_trap_va_in         ( mem_trap_va_in       ),
    .mem_trap_mode_in       ( mem_trap_mode_in     ),
    .mem_trap_commit_out    ( mem_trap_commit_out  ),
    .ex_rd_sel_in           ( ex_rd_sel_in         ),
    .mem_rd_sel_in          ( mem_rd_sel_in        ),
    .wb_rd_sel_in           ( rd_sel_in            ),
    .ex_muldiv_active_in    ( ex_muldiv_active_in  ),
    .ex_csr_en_in           ( ex_csr_en_in         ),
    .mem_csr_en_in          ( mem_csr_en_in        ),
    .wb_csr_en_in           ( wb_csr_en_in         ),
    .ex_mem_inflight_in     ( ex_mem_inflight_in   ),
    .mem_mem_inflight_in    ( mem_mem_inflight_in  ),
    .mstatus_in             ( mstatus              ),
    .mtvec_in               ( mtvec                ),
    .stvec_in               ( stvec                ),
    .medeleg_in             ( medeleg              ),
    .mideleg_in             ( mideleg              ),
    .mie_in                 ( mie                  ),
    .dcsr_in                ( dcsr                 ),
    .dpc_in                 ( dpc                  ),
    .sepc_in                ( sepc                 ),
    .mepc_in                ( mepc                 ),
    .ssip_in                ( ssip                 ),
    .stip_eff_in            ( stip_eff             ),
    .seip_eff_in            ( seip_eff             ),
    .tvec_out               ( tvec_out             ),
    .epc_out                ( epc_out              ),
    .trap_out               ( trap_out             ),
    .trap_pending_out       ( trap_pending_out     ),
    .ret_out                ( ret_out              ),
    .ret_commit_in          ( ret_commit_in        ),
    .mode_out               ( current_mode         ),
    .debug_mode_out         ( debug_mode_active    ),
    .trap_csr_en_out        ( trap_csr_en          ),
    .trap_to_debug_out      ( trap_to_debug        ),
    .trap_to_s_out          ( trap_to_s            ),
    .trap_epc_out           ( trap_epc             ),
    .trap_cause_out         ( trap_cause           ),
    .trap_tval_out          ( trap_tval            ),
    .trap_mode_out          ( trap_mode            ),
    .dcsr_cause_out         ( dcsr_cause           ),
    .mret_commit_out        ( mret_commit          ),
    .sret_commit_out        ( sret_commit          ),
    .dret_commit_out        ( dret_commit          )
);

// ============================================================
// Immediate generation
// ============================================================

always_comb begin
    case (imm_sel)
        I_TYPE:  imm32_out = {{21{ir_buff.b[31]}}, ir_buff.b[30:20]};
        I2_TYPE: imm32_out = {27'h0, ir_buff.b[24:20]};
        S_TYPE:  imm32_out = {{21{ir_buff.b[31]}}, ir_buff.b[30:25], ir_buff.b[11:7]};
        B_TYPE:  imm32_out = {{20{ir_buff.b[31]}}, ir_buff.b[7], ir_buff.b[30:25], ir_buff.b[11:8], 1'b0};
        U_TYPE:  imm32_out = {ir_buff.b[31], ir_buff.b[30:12], 12'b0};
        J_TYPE:  imm32_out = {{12{ir_buff.b[31]}}, ir_buff.b[19:12], ir_buff.b[20], ir_buff.b[30:21], 1'b0};
        ZERO:    imm32_out = 32'h0;
        NEXT_PC: imm32_out = pc_plus_4_buff;
        default: imm32_out = 32'h0;
    endcase
end

// ============================================================
// Early JAL/JALR
// ============================================================

addr_t jal_target;
assign jal_target_out = jal_ok_out ? jal_target : '0;

// Compute target_misaligned independently of trap_out to avoid a combinatorial loop.
// target_misaligned is only active when the instruction is a JAL/JALR and the target address is misaligned.
// misaligned_tartget is the computed target address for JAL/JALR, used to update tval, 0 otherwise.
always_comb begin
    if (ir_buff.r.opcode == JALR) begin
        automatic addr_t jalr_base = (rd_sel_in != 0 && ir_buff.r.rs1 == rd_sel_in) ? rd_data_in : jump_base;
        automatic data_t jalr_imm = {{21{ir_buff.b[31]}}, ir_buff.b[30:20]};
        automatic addr_t target = (jalr_base + jalr_imm) & ~ 32'd1;
        target_misaligned = target[1] && instr_valid_buff;
        misaligned_target = target;
    end else if (ir_buff.r.opcode == JAL) begin
        automatic data_t jal_imm = {{12{ir_buff.b[31]}}, ir_buff.b[19:12], ir_buff.b[20], ir_buff.b[30:21], 1'b0};
        automatic addr_t target = pc_in_buff + jal_imm;
        target_misaligned = target[1] && instr_valid_buff;
        misaligned_target = target;
    end else begin
        target_misaligned = 1'b0;
        misaligned_target = '0;
    end
end

// Compute the final target of a JAL/JALR.
// This is separate from the target_misaligned logic to avoid a combinatorial loop in trap detection.
always_comb begin
    if (!trap_out) begin
        automatic addr_t jal_target_base = '0;
        automatic data_t jal_imm = '0;
        if (ir_buff.r.opcode == JALR) begin
            jal_ok_out = !target_misaligned;
            jal_target_base = (rd_sel_in != 0 && ir_buff.r.rs1 == rd_sel_in) ? rd_data_in : jump_base;
            jal_imm = {{21{ir_buff.b[31]}}, ir_buff.b[30:20]};  // I-type immediate
            jal_target = (jal_target_base + jal_imm) & ~32'h1;
        end else if (ir_buff.r.opcode == JAL) begin
            jal_ok_out = !target_misaligned;
            jal_imm = {{12{ir_buff.b[31]}}, ir_buff.b[19:12], ir_buff.b[20], ir_buff.b[30:21], 1'b0};  // J-type immediate
            jal_target = pc_in_buff + jal_imm;
        end else begin
            jal_ok_out = 1'b0;
            jal_target = '0;
        end
    end else begin
        jal_ok_out = 1'b0;
        jal_target = '0;
    end
end

// ============================================================
// Instruction decoding
// ============================================================

friscv_id_decoder #(
    .ENABLE_EXTENSION_A ( ENABLE_EXTENSION_A ),
    .ENABLE_MUL         ( ENABLE_MUL         ),
    .ENABLE_DIV         ( ENABLE_DIV         )
) friscv_id_decoder (
    .ir_in                  ( ir_buff             ),
    .mode_in                ( current_mode        ),
    .dbg_active_in          ( debug_mode_active   ),
    .tvm_in                 ( mstatus.tvm         ),
    .csr_not_implemented_in ( csr_not_implemented ),
    .mcounteren_in          ( mcounteren          ),
    .scounteren_in          ( scounteren          ),
    .instr_valid            ( instr_valid_buff    ),
    .instr_ex_out           ( instr_ex_out        ),
    .rs1_sel_out            ( rs1_sel_out         ),
    .rs2_sel_out            ( rs2_sel_out         ),
    .rd_sel_out             ( rd_sel_out          ),
    .imm_sel_out            ( imm_sel             ),
    .illegal_inst_out       ( illegal_inst        ),
    .ecall_active_out       ( ecall_active        ),
    .ebreak_active_out      ( ebreak_active       )
);

endmodule

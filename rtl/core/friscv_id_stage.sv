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
 * - Reading the register file for source operands
 * - Decoding the instruction and generating control signals for the EX stage (friscv_id_decoder.sv)
 * - Handling CSR reads and writes, including maintaining a CSR file and implementing trap logic
 * - Detecting and prioritizing traps and interrupts, with support for delegation to S-mode
 * - Interfacing with the pipeline control logic for stalling and flushing
 *
 * The ID stage is the module that commits traps, meaning it determines when a trap should be taken, and from what source.
 * It then confirms to the trapping stage that its trap is being handled (through x_trap_commit_out).
 *
 * A trap is commited on the first cycle that the ID stage detects a trap and there are no hazards with data relevant to
 * the trap (e.g. a CSR write that would update mtvec before the trap is taken).
 */

// TODO break this module up into (or similar):
//  - csr_file
//  - trap_handler

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_id_stage #(
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
    parameter int   PMP_ENTRIES = 64,
    parameter int   PMP_USABLE  = 64,

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

// M extension configured by choosing MUL and DIV
localparam logic ENABLE_EXTENSION_M = ENABLE_MUL && ENABLE_DIV;

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

// Current privilege mode of the hart.
mode_e r_current_mode;
logic  debug_mode_active;

addr_t jump_base;

friscv_id_regfile regfile (
    .clk_in           ( clk_in        ),
    .rst_n_in         ( rst_n_in      ),
    .rs1_sel_in       ( rs1_sel_out   ),
    .rs2_sel_in       ( rs2_sel_out   ),
    .jump_base_sel_in ( ir_buff.r.rs1 ),
    .rd_sel_in        ( rd_sel_in     ),
    .rd_data_in       ( rd_data_in    ),
    .rs1_data_out     ( rs1_out       ),
    .rs2_data_out     ( rs2_out       ),
    .jump_base_out    ( jump_base     )
);

// ============================================================
// Input capture
// ============================================================

always_ff @(posedge clk_in) begin
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
            pc_mode_buff        <= r_current_mode;
        end
    end
end

// ============================================================
// Control and Status Registers
// ============================================================

// CSR file definition
// Read-only CSRs are not stored here, they are hardwired in the read block
typedef struct packed {
    // Supervisor Interrupt Pending
    logic ssip;
    logic stip;
    logic seip;

    // Supervisor Trap Setup
    data_t scounteren;
    addr_t stvec;
    data_t senvcfg;

    // Supervisor Trap Handling
    data_t sscratch;
    addr_t sepc;
    data_t scause;
    inst_t stval;

    // Supervisor Timer (Sstc)
    data_t stimecmp;
    data_t stimecmph;

    // Supervisor Protection and Translation
    satp_t satp;

    // Machine Information Registers
    // Hardwired in read block

    // Machine Trap Setup
    mstatus_t mstatus;
    data_t medeleg;
    data_t mideleg;
    data_t mie;
    addr_t mtvec;
    data_t mcounteren;

    // Core Debug Registers
    dcsr_t dcsr;
    addr_t dpc;
    data_t dscratch0;
    data_t dscratch1;

    // Machine Trap Handling
    data_t mscratch;
    addr_t mepc;
    data_t mcause;
    inst_t mtval;

    // Machine Environment Configuration
    data_t menvcfg;
    data_t menvcfgh;

    // Machine Counter/Timers
    logic [63:0] mcycle;
    logic [63:0] minstret;

    // Machine Counter Setup
    data_t mcountinhibit;
} csr_file_t;

csr_file_t csr;

logic dcsr_ebreak_eff;
always_comb case (r_current_mode)
    M_MODE:  dcsr_ebreak_eff = csr.dcsr.ebreakm;
    H_MODE:  dcsr_ebreak_eff = csr.dcsr.ebreakm;
    S_MODE:  dcsr_ebreak_eff = csr.dcsr.ebreaks;
    U_MODE:  dcsr_ebreak_eff = csr.dcsr.ebreaku;
    default: dcsr_ebreak_eff = csr.dcsr.ebreaku;
endcase

pmp_entry_t [PMP_ENTRIES-1:0] pmp_table;
assign pmp_table_out = pmp_table;

// Pack a pmp_cfg_t struct into its 8-bit pmpcfg byte
function automatic logic [7:0] pmpcfg_of(pmp_cfg_t pmp_cfg);
    pmpcfg_of = {pmp_cfg.l, 2'b00, pmp_cfg.a, pmp_cfg.x, pmp_cfg.w, pmp_cfg.r};
endfunction

// Decode an 8-bit pmpcfg byte into a pmp_cfg_t struct
function automatic pmp_cfg_t cfg_from_byte(logic [7:0] b);
    if (b[1] && !b[0]) cfg_from_byte = '{l: b[7], a: pmp_mode_e'(b[4:3]), x: 1'b0, w: 1'b0, r: 1'b0};
    else               cfg_from_byte = '{l: b[7], a: pmp_mode_e'(b[4:3]), x: b[2], w: b[1], r: b[0]};
endfunction

// Pack the four cfg bytes of pmpcfg<regn>
function automatic data_t pmpcfg_word(int regn);
    pmpcfg_word = {pmpcfg_of(pmp_table[regn*4+3].cfg), pmpcfg_of(pmp_table[regn*4+2].cfg),
                   pmpcfg_of(pmp_table[regn*4+1].cfg), pmpcfg_of(pmp_table[regn*4+0].cfg)};
endfunction

// Extract selected CSR address from the instruction word
// This will store garbage if not a CSR instruction, but that's ok.
csr_addr_e selected_csr;
assign selected_csr = csr_addr_e'(ir_buff.b[31:20]);

// Read-only status of CSR being WRITTEN BACK
// This is to protect the state of read-only CSRs, but should never be true
// as writes to read-only CSRs will be decoded as illegal instructions and trap.
logic wb_csr_ro;
assign wb_csr_ro = csr_sel_in[11:10] == 2'b11;

// ============================================================
// Single step debug logic
// ============================================================

typedef enum logic [1:0] {
    STEP_OFF,
    STEP_ARMED,
    STEP_FIRE
} step_e;

step_e r_step;

// An instruction leaves ID this cycle
logic id_dispatch;
assign id_dispatch = instr_valid_buff && !stage_stall_in && !flush_in
                     && !trap_out && !trap_pending_out;

// ============================================================
// Trap logic
// ============================================================

logic r_mret_inhibit;

// Check if interrupt is safe to execute - safe if
//  1) Not returning from a previous interrupt,
//  2) Not executing a branch and
//  3) Not in the middle of a fetch
// This is to prevent a taken interrupt killing valid instructions, or ret being skipped.
// A previous interrupt must safely exit before taking the next interrupt.
logic interrupt_safe;
assign interrupt_safe = !r_mret_inhibit && !branch_ok_in && (|pc_in_buff) && !debug_mode_active;

// A synchronous exception is safe only if the buffer holds a valid instruciton,
// and a redirect is not being processed that would kill the trapping instruction anyway (branch_ok_in).
logic exception_safe;
assign exception_safe = !branch_ok_in && instr_valid_buff;

// Interrupt detection ========================================

// STIP has two sources:
//  1) Hardware: when mtime >= stimecmp, and menvcfgh[31] enables this behavior
//  2) Software: when M-mode or S-mode writes to the STIP bit in mip
// stip_eff is the effective STIP value taking both into account.
logic stip_hw;
logic stip_eff;
assign stip_hw  = csr.menvcfgh[31] && (mtime_in >= {csr.stimecmph, csr.stimecmp});
assign stip_eff = csr.stip || stip_hw;

logic seip_eff;
assign seip_eff = csr.seip || seip_in;

// m_interrupt_active if an interrupt to M-mode is pending and not masked or delegated.
// This interrupt will be taken as soon as it is safe to do so.
logic m_interrupt_active;
assign m_interrupt_active = interrupt_safe &&
                            r_step == STEP_OFF &&
                            (csr.mstatus.mie || r_current_mode != M_MODE) &&
                            ((msip_in && csr.mie[3]) ||
                             (mtip_in && csr.mie[7]) ||
                             (meip_in && csr.mie[11]));

// s_interrupt_active if an interrupt to S-mode is pending and not masked, delegated, or overridden by an M-mode interrupt.
// This interrupt will be taken as soon as it is safe to do so and there are no M-mode interrupts.
logic s_interrupt_active;
assign s_interrupt_active = interrupt_safe &&
                            r_step == STEP_OFF &&
                            (r_current_mode != M_MODE) &&
                            (csr.mstatus.sie || r_current_mode == U_MODE) &&
                            ((csr.ssip && csr.mie[1] && csr.mideleg[1]) ||
                             (stip_eff && csr.mie[5] && csr.mideleg[5]) ||
                             (seip_eff && csr.mie[9] && csr.mideleg[9]));

// An interrupt is active (pending or being taken) if either an M-mode or S-mode interrupt is active.
// All required gating is done by m_interrupt_active and s_interrupt_active.
logic interrupt_active;
assign interrupt_active = m_interrupt_active || s_interrupt_active;

// Exception detection ========================================

// IF stage traps can be page faults or access faults.
// These are propagated to ID with a cycle of latency and come with the relevant faulting instruction.
typedef enum logic [1:0] {
    IF_TRAP_NONE,
    IF_TRAP_FAULT,
    IF_TRAP_ACCESS
} if_trap_e;

if_trap_e if_trap;
assign if_trap = inst_fault_buff                      ? IF_TRAP_FAULT  :
                 inst_err_buff || inst_pmp_fault_buff ? IF_TRAP_ACCESS :
                                                        IF_TRAP_NONE;

// An IF exception is not taken if there is a branch redirect in-flight that would kill the trapping instruction anyway, or if the trap is currently inhibited.
logic if_trap_inhibit;
logic is_if_trap;
assign is_if_trap = (if_trap != IF_TRAP_NONE) && !if_trap_inhibit && !branch_ok_in;

logic ecall_active, ebreak_active;
logic target_misaligned;
addr_t misaligned_target;

logic is_mem_trap;
assign is_mem_trap = mem_trap_in != MEM_TRAP_NONE;

logic is_ex_trap;
assign is_ex_trap = ex_trap_in != EX_TRAP_NONE;

logic exception_other;
assign exception_other = is_if_trap || is_ex_trap || is_mem_trap;

// Enter debug on ebreak if it is safe to redirect, the current mode allows it (dcsr.ebreakm/s/u),
// not currently in debug mode, and no exception from an older instruction is being taken.
logic ebreak_to_debug;
assign ebreak_to_debug = exception_safe && ebreak_active && dcsr_ebreak_eff
                         && !debug_mode_active && !exception_other;

// The exception is originating from ID if it is ecall, ebreak, illegal instruction, or jump target misaligned.
logic illegal_inst;
logic is_id_trap;
assign is_id_trap = exception_safe &&
                    (ecall_active  ||
                     (ebreak_active && !ebreak_to_debug) ||
                     illegal_inst  ||
                     target_misaligned);

// Select where the exception is originating from to determine which exception has priority.
typedef enum logic [2:0] {
    TRAP_SRC_NONE,
    TRAP_SRC_MEM,
    TRAP_SRC_EX,
    TRAP_SRC_ID,
    TRAP_SRC_IF
} trap_src_e;

// The IF exception is special - it is generated by the instruction currently in
// the ID stage, not IF. It indicates that the instruction access or page faulted.
// That is why IF exceptions have priority over ID exceptions.
// Example: a fetch of an illegal instruction page faulted. The first fault of this
// instruction is in IF (page fault), and it being illegal as raised by ID is secondary,
// thus IF exceptions have priority over ID exceptions.
trap_src_e trap_src;
assign trap_src =
    is_mem_trap ? TRAP_SRC_MEM :
    is_ex_trap  ? TRAP_SRC_EX  :
    is_if_trap  ? TRAP_SRC_IF  :
    is_id_trap  ? TRAP_SRC_ID  :
                  TRAP_SRC_NONE;

// An exception is active (pending) if any of the exception sources are active.
logic exception_active;
assign exception_active = is_if_trap || is_id_trap || is_ex_trap || is_mem_trap;

logic debug_halt_entry;
assign debug_halt_entry = !debug_mode_active && interrupt_safe &&
                          (dbg_req_in || (r_step == STEP_FIRE));

logic debug_entry;
assign debug_entry = ebreak_to_debug || (debug_halt_entry && !exception_active);

// Trap RAW hazard - a CSR write in EX or MEM might update mtvec/mstatus/mepc before the
// trap fires. Suppress the effective trap (flush + CSR state write) until the pipeline
// is clear. trap_pending_out lets pipeline_control stall so the instruction is not lost
// from ir_buff while waiting.
logic trap_raw, trap_csr_hazard;
logic trap_gpr_hazard;
assign trap_raw         = interrupt_active || exception_active || debug_entry;
assign trap_csr_hazard  = trap_raw && (ex_csr_en_in || mem_csr_en_in || wb_csr_en_in);
assign trap_gpr_hazard  = trap_raw &&
                          ((ex_rd_sel_in  != 5'd0) ||
                           (mem_rd_sel_in != 5'd0) ||
                           (rd_sel_in     != 5'd0));

// Flag to not re-take an already taken trap.
logic trap_seen;
logic r_in_ebreak_handler;

// An incoming trap has a pipeline hazard if
//  1) there is a memory instruction in the pipeline or
//  2) a dispatched instruction will write back to a register or
//  3) an iterative multiply/divide operation is still active.
// These must commit before taking a trap.
logic trap_pipe_hazard;
assign trap_pipe_hazard = trap_raw &&
                          (ex_mem_inflight_in || mem_mem_inflight_in ||
                           ex_muldiv_active_in || trap_gpr_hazard);
assign trap_out         = trap_raw && !trap_seen && !trap_csr_hazard && !trap_pipe_hazard;
assign trap_pending_out = trap_raw && !trap_seen && (trap_csr_hazard || trap_pipe_hazard);

// Signal the EX or MEM stage that their trap is being taken, so they can kill their instructions.
assign ex_trap_commit_out  = trap_out && (trap_src == TRAP_SRC_EX || trap_src == TRAP_SRC_MEM);
assign mem_trap_commit_out = trap_out && (trap_src == TRAP_SRC_MEM);

// MRET and SRET are detected outside the main decoder to avoid a combinatorial loop and improve timing.
logic mret_active, sret_active, dret_active;
assign mret_active = (ir_buff.r.opcode == SYSTEM) && (ir_buff.r.funct3 == 3'b000) && (ir_buff.b[31:20] == 12'b001100000010);
assign sret_active = (ir_buff.r.opcode == SYSTEM) && (ir_buff.r.funct3 == 3'b000) && (ir_buff.b[31:20] == 12'b000100000010);
assign dret_active = (ir_buff.r.opcode == SYSTEM) && (ir_buff.r.funct3 == 3'b000) && (ir_buff.b[31:20] == 12'b011110110010);

// Signal to the control logic that a return instruction is being taken.
assign ret_out = (mret_active || sret_active || dret_active) && !illegal_inst;

// Generate Cause Code ========================================

// Take the exception source decoded above and generate the corresponding exception cause code.
logic [4:0] exception_cause_code;
always_comb begin
    exception_cause_code = 5'd0;  // No exception by default
    case (trap_src)
        TRAP_SRC_IF:
            case (if_trap)
                IF_TRAP_FAULT:  exception_cause_code = 5'd12;  // Instruction page fault
                IF_TRAP_ACCESS: exception_cause_code = 5'd1;   // Instruction access fault
                default:        exception_cause_code = 5'd0;   // No exception
            endcase
        TRAP_SRC_ID:
            if (ecall_active)
                case (r_current_mode)
                    U_MODE:  exception_cause_code = 5'd8;   // Environment call from U-mode
                    S_MODE:  exception_cause_code = 5'd9;   // Environment call from S-mode
                    default: exception_cause_code = 5'd11;  // Environment call from M-mode
                endcase
            else if (ebreak_active)
                exception_cause_code = 5'd3;  // Breakpoint
            else if (illegal_inst)
                exception_cause_code = 5'd2;  // Illegal instruction
            else if (target_misaligned)
                exception_cause_code = 5'd0;  // Instruction address misaligned
        TRAP_SRC_EX:
            case (ex_trap_in)
                EX_TRAP_MISALIGNED: exception_cause_code = 5'd0;  // Instruction address misaligned
                default:            exception_cause_code = 5'd0;  // No exception
            endcase
        TRAP_SRC_MEM:
            case (mem_trap_in)
                MEM_TRAP_LOAD_MISALIGNED:  exception_cause_code = 5'd4;   // Load address misaligned
                MEM_TRAP_LOAD_ACCESS:      exception_cause_code = 5'd5;   // Load access fault
                MEM_TRAP_STORE_MISALIGNED: exception_cause_code = 5'd6;   // Store/AMO address misaligned
                MEM_TRAP_STORE_ACCESS:     exception_cause_code = 5'd7;   // Store/AMO access fault
                MEM_TRAP_LOAD:             exception_cause_code = 5'd13;  // Load page fault
                MEM_TRAP_STORE:            exception_cause_code = 5'd15;  // Store/AMO page fault
                default:                   exception_cause_code = 5'd0;   // No exception
            endcase
        default: exception_cause_code = 5'd0;
    endcase
end

assign halt_out = (ENABLE_HALT_ON_ENTER_EBREAK && ebreak_active) ||
                  (ENABLE_HALT_ON_RET_FROM_EBREAK && r_in_ebreak_handler && (instr_ex_out.mret_en || instr_ex_out.sret_en));

// A trap is delegated to S-mode when:
//   - Not already in M-mode (traps never transition to less-privileged mode)
//   - No M-mode interrupt is active (M-mode interrupts take priority over S-mode)
//   - s_interrupt_active (already checks mideleg bits), or
//   - exception cause bit is set in medeleg
logic is_delegated;

mode_e trap_mode;
always_comb begin
    case (trap_src)
        TRAP_SRC_IF:   trap_mode = pc_mode_buff;
        TRAP_SRC_ID:   trap_mode = r_current_mode;
        TRAP_SRC_EX:   trap_mode = ex_trap_mode_in;
        TRAP_SRC_MEM:  trap_mode = mem_trap_mode_in;
        TRAP_SRC_NONE: trap_mode = r_current_mode;
        default:       trap_mode = r_current_mode;
    endcase
end

assign is_delegated = (trap_mode != M_MODE) &&
                      !m_interrupt_active &&
                      (s_interrupt_active || (exception_active && csr.medeleg[exception_cause_code]));

logic trap_to_s_mode;
assign trap_to_s_mode = trap_out && is_delegated;

// Interrupt cause code for vectored tvec offset
logic [31:0] current_cause;
always_comb begin
    if (meip_in && csr.mie[11])
        current_cause = 32'd11;
    else if (mtip_in && csr.mie[7])
        current_cause = 32'd7;
    else if (msip_in && csr.mie[3])
        current_cause = 32'd3;
    else if (seip_eff && csr.mie[9] && csr.mideleg[9])
        current_cause = 32'd9;
    else if (stip_eff && csr.mie[5] && csr.mideleg[5])
        current_cause = 32'd5;
    else if (csr.ssip && csr.mie[1] && csr.mideleg[1])
        current_cause = 32'd1;
    else
        current_cause = 32'd0;
end

// Return address used by mret/sret
assign epc_out = dret_active ? csr.dpc  :
                 sret_active ? csr.sepc :
                               csr.mepc;

// Trap vector, resolved to correct mode with vectored mode
assign tvec_out = debug_mode_active && exception_active
                  ? ((trap_src == TRAP_SRC_ID && ebreak_active)
                     ? DM_BASE + DM_HALT_OFFSET
                     : DM_BASE + DM_EXC_OFFSET)
                  : debug_entry
                  ? DM_BASE + DM_HALT_OFFSET
                  : trap_to_s_mode
                  ? ((csr.stvec[1:0] == 2'b01 && interrupt_active)
                     ? {csr.stvec[31:2], 2'b0} + {current_cause[29:0], 2'b0}  // vectored S-mode trap
                     : {csr.stvec[31:2], 2'b0})                               // direct S-mode trap
                  : ((csr.mtvec[1:0] == 2'b01 && interrupt_active)
                     ? {csr.mtvec[31:2], 2'b0} + {current_cause[29:0], 2'b0}  // vectored M-mode trap
                     : {csr.mtvec[31:2], 2'b0});                              // direct M-mode trap

// ============================================================
// Trap EPC and TVAL resolution
// ============================================================

addr_t trap_epc;
always_comb begin
    case (trap_src)
        TRAP_SRC_IF:   trap_epc = pc_in_buff;
        TRAP_SRC_ID:   trap_epc = pc_in_buff;
        TRAP_SRC_EX:   trap_epc = ex_trap_pc_in;
        TRAP_SRC_MEM:  trap_epc = mem_trap_pc_in;
        TRAP_SRC_NONE: trap_epc = pc_in_buff;
        default:       trap_epc = pc_in_buff;
    endcase
end

addr_t trap_tval;
always_comb begin
    case (trap_src)
        TRAP_SRC_IF:  trap_tval = (if_trap == IF_TRAP_ACCESS) ? '0 : fault_addr_buff;
        TRAP_SRC_ID:  trap_tval = illegal_inst      ? ir_buff.b         :
                                  target_misaligned ? misaligned_target : '0;
        TRAP_SRC_EX:  trap_tval = ex_trap_va_in;
        TRAP_SRC_MEM:
            case (mem_trap_in)
                MEM_TRAP_LOAD_ACCESS,
                MEM_TRAP_STORE_ACCESS: trap_tval = '0;
                default:               trap_tval = mem_trap_va_in;
            endcase
        TRAP_SRC_NONE: trap_tval = '0;
        default:       trap_tval = '0;
    endcase
end

// ============================================================
// CSR write
// ============================================================

// Ignore a write to pmpaddr if
//  1) This entry is locked or
//  2) The following entry is TOR and locked
function automatic logic pmpaddr_write_ignored(int i);
    pmpaddr_write_ignored = pmp_table[i].cfg.l ||
                            (i < PMP_ENTRIES-1 &&
                             pmp_table[i+1].cfg.a == PMP_TOR &&
                             pmp_table[i+1].cfg.l);
endfunction

always_ff @(posedge clk_in) begin
    if(!rst_n_in) begin
        csr <= '0;
        csr.dcsr.debugver <= 4;  // Debug specification version 1.0 implemented
        csr.dcsr.prv      <= M_MODE;

        r_mret_inhibit      <= 1'b0;
        r_current_mode      <= M_MODE;
        debug_mode_active   <= 1'b0;
        trap_seen           <= 1'b0;
        if_trap_inhibit     <= 1'b0;
        r_in_ebreak_handler <= 1'b0;
        r_step              <= STEP_OFF;
    end else begin
        if (!trap_raw)
            trap_seen <= 1'b0;

        if (r_mret_inhibit && !stage_stall_in)
            r_mret_inhibit <= 1'b0;

        if (trap_out)
            if_trap_inhibit <= 1'b1;
        else if (!stage_stall_in && !(inst_fault_in || inst_err_in || inst_pmp_fault_in))
            if_trap_inhibit <= 1'b0;

        case (r_step)
            STEP_ARMED: if (id_dispatch || trap_out) r_step <= STEP_FIRE;
            STEP_OFF, STEP_FIRE: ;
            default: ;
        endcase

        if (trap_out) begin
            trap_seen <= 1'b1;
            r_mret_inhibit <= 1'b0;

            if (trap_src == TRAP_SRC_ID && ebreak_active)
                r_in_ebreak_handler <= 1'b1;

            if (debug_mode_active) begin
                // Exception in D-mode redirects only
                // No mepc/mcause/etc update

            end else if (debug_entry) begin
                debug_mode_active <= 1'b1;
                csr.dpc           <= trap_epc;
                csr.dcsr.prv      <= r_current_mode;
                csr.dcsr.cause    <= dbg_req_in      ? 3'd3 : // haltreq
                                     ebreak_to_debug ? 3'd1 : // ebreak
                                                       3'd4;  // step
                r_current_mode    <= M_MODE;
                r_step            <= STEP_OFF;

            end else if (trap_to_s_mode) begin
                r_current_mode   <= S_MODE;
                csr.sepc         <= trap_epc;
                csr.mstatus.spie <= csr.mstatus.sie;
                csr.mstatus.sie  <= 1'b0;
                csr.mstatus.spp  <= (trap_mode == S_MODE) ? 1'b1 : 1'b0;
                csr.stval        <= trap_tval;

                if      (seip_eff && csr.mie[9] && csr.mideleg[9]) csr.scause <= {1'b1, 31'd9};
                else if (stip_eff && csr.mie[5] && csr.mideleg[5]) csr.scause <= {1'b1, 31'd5};
                else if (csr.ssip && csr.mie[1] && csr.mideleg[1]) csr.scause <= {1'b1, 31'd1};
                else if (exception_active)                         csr.scause <= 32'(exception_cause_code);

            end else begin
                // Non-delegated trap: enter M-mode
                r_current_mode <= M_MODE;
                csr.mepc            <= trap_epc;
                csr.mstatus.mpie    <= csr.mstatus.mie;
                csr.mstatus.mie     <= 1'b0;
                csr.mstatus.mpp     <= trap_mode;
                csr.mtval           <= trap_tval;

                if      (meip_in && csr.mie[11])         csr.mcause <= {1'b1, 31'd11};
                else if (mtip_in && csr.mie[7])          csr.mcause <= {1'b1, 31'd7};
                else if (msip_in && csr.mie[3])          csr.mcause <= {1'b1, 31'd3};
                else if (exception_active)               csr.mcause <= 32'(exception_cause_code);
            end

        end else if (ret_commit_in && dret_active) begin
            r_mret_inhibit    <= 1'b1;
            debug_mode_active <= 1'b0;
            r_current_mode    <= csr.dcsr.prv;
            r_step            <= csr.dcsr.step ? STEP_ARMED : STEP_OFF;

        end else if (ret_commit_in && sret_active) begin
            r_mret_inhibit   <= 1'b1;
            csr.mstatus.sie  <= csr.mstatus.spie;
            csr.mstatus.spie <= 1'b1;
            r_current_mode   <= csr.mstatus.spp ? S_MODE : U_MODE;
            csr.mstatus.spp  <= 1'b0;

        end else if (ret_commit_in && mret_active) begin
            // Commit MRET
            r_mret_inhibit   <= 1'b1;
            csr.mstatus.mie  <= csr.mstatus.mpie;
            csr.mstatus.mpie <= 1'b1;
            r_current_mode   <= csr.mstatus.mpp;
            csr.mstatus.mpp  <= U_MODE;
            if (csr.mstatus.mpp != M_MODE)
                csr.mstatus.mprv <= 1'b0;

        end else if (csr_en_in && instr_ret_in && !wb_csr_ro) begin
            case (csr_sel_in)
                // Supervisor Trap Setup (aliased into mstatus/mie)
                CSR_SSTATUS: begin
                    csr.mstatus.sie  <= csr_data_in[1];
                    csr.mstatus.spie <= csr_data_in[5];
                    csr.mstatus.spp  <= csr_data_in[8];
                    csr.mstatus.sum  <= csr_data_in[18];
                    csr.mstatus.mxr  <= csr_data_in[19];
                end
                CSR_SCOUNTEREN: csr.scounteren <= csr_data_in & 32'h0000_0007;
                CSR_SIE: begin  // S-mode visible bits of mie only
                    csr.mie[1] <= csr_data_in[1];
                    csr.mie[5] <= csr_data_in[5];
                    csr.mie[9] <= csr_data_in[9];
                end
                CSR_STVEC:    csr.stvec    <= csr_data_in;
                CSR_SENVCFG:  csr.senvcfg  <= csr_data_in;
                CSR_SSCRATCH: csr.sscratch <= csr_data_in;
                CSR_SEPC:     csr.sepc     <= csr_data_in;
                CSR_SCAUSE:   csr.scause   <= csr_data_in;
                CSR_STVAL:    csr.stval    <= csr_data_in;
                CSR_SIP: begin  // SSIP writable by S-mode; STIP/SEIP only by M-mode
                    csr.ssip <= csr_data_in[1];
                    if (r_current_mode == M_MODE) begin
                        csr.stip <= csr_data_in[5];
                        csr.seip <= csr_data_in[9];
                    end
                end

                // Supervisor Timer (Sstc)
                CSR_STIMECMP:  csr.stimecmp  <= csr_data_in;
                CSR_STIMECMPH: csr.stimecmph <= csr_data_in;

                // Supervisor Protection and Translation
                CSR_SATP: csr.satp <= csr_data_in;

                // Machine Trap Setup
                CSR_MSTATUS: begin
                    csr.mstatus.sie  <= csr_data_in[1];
                    csr.mstatus.mie  <= csr_data_in[3];
                    csr.mstatus.spie <= csr_data_in[5];
                    csr.mstatus.mpie <= csr_data_in[7];
                    csr.mstatus.spp  <= csr_data_in[8];
                    csr.mstatus.mpp  <= mode_e'(csr_data_in[12:11]);
                    csr.mstatus.mprv <= csr_data_in[17];
                    csr.mstatus.sum  <= csr_data_in[18];
                    csr.mstatus.mxr  <= csr_data_in[19];
                    csr.mstatus.tvm  <= csr_data_in[20];
                end
                CSR_MEDELEG:    csr.medeleg    <= csr_data_in;
                CSR_MIDELEG:    csr.mideleg    <= csr_data_in & 32'h0000_0222;  // Bits 1,5,9 only
                CSR_MIE:        csr.mie        <= csr_data_in;
                CSR_MTVEC:      csr.mtvec      <= csr_data_in;
                CSR_MCOUNTEREN: csr.mcounteren <= csr_data_in & 32'h0000_0007;
                CSR_MENVCFG:    csr.menvcfg    <= csr_data_in;
                CSR_MENVCFGH:   csr.menvcfgh   <= csr_data_in;
                CSR_MIP: begin  // S-mode soft interrupt bits writable through mip
                    csr.ssip <= csr_data_in[1];
                    csr.stip <= csr_data_in[5];
                    csr.seip <= csr_data_in[9];
                end

                // Machine Trap Handling
                CSR_MSCRATCH: csr.mscratch <= csr_data_in;
                CSR_MEPC:     csr.mepc     <= csr_data_in;
                CSR_MCAUSE:   csr.mcause   <= csr_data_in;

                // Machine Memory Protection: handled below (index-computed)

                // Machine Counter Setup
                CSR_MCOUNTINHIBIT: csr.mcountinhibit <= csr_data_in & 32'h0000_0005;

                // Core Debug Registers
                CSR_DCSR: begin
                    csr.dcsr.ebreakm   <= csr_data_in[15];
                    csr.dcsr.ebreaks   <= csr_data_in[13];
                    csr.dcsr.ebreaku   <= csr_data_in[12];
                    csr.dcsr.stopcount <= csr_data_in[10];
                    csr.dcsr.step      <= csr_data_in[2];
                    csr.dcsr.prv       <= (csr_data_in[1:0] == 2'b10) 
                                          ? M_MODE : mode_e'(csr_data_in[1:0]);
                end
                CSR_DPC:       csr.dpc       <= csr_data_in & ~32'h3;
                CSR_DSCRATCH0: csr.dscratch0 <= csr_data_in;
                CSR_DSCRATCH1: csr.dscratch1 <= csr_data_in;

                default: ;
            endcase
        end

        // Update counters if not in debug mode with stopcount set
        if (!(debug_mode_active && csr.dcsr.stopcount)) begin
            // Cycle counter
            if (!csr.mcountinhibit[0]) csr.mcycle <= csr.mcycle + 1;
            // Instruction retire counter
            if (instr_ret_in && !csr.mcountinhibit[2]) csr.minstret <= csr.minstret + 1;
        end
    end
end

// ============================================================
// Machine Memory Protection
// ============================================================

if (ENFORCE_PMP) begin : gen_pmp_table
    logic pmp_csr_wr;
    assign pmp_csr_wr = !trap_out &&
                        !(ret_commit_in && (sret_active || mret_active)) &&
                        csr_en_in && instr_ret_in && !wb_csr_ro;

    always_ff @(posedge clk_in) begin
        if (!rst_n_in) begin
            pmp_table <= '0;
        end else if (pmp_csr_wr) begin
            if (int'(csr_sel_in) >= int'(CSR_PMPCFG0) &&
                int'(csr_sel_in) <  int'(CSR_PMPCFG0) + PMP_ENTRIES/4) begin
                // Writing to pmpcfg
                automatic int base = (int'(csr_sel_in) - int'(CSR_PMPCFG0)) * 4;
                for (int j = 0; j < 4; j++) begin
                    automatic int i = base + j;
                    // Only the first PMP_USABLE entries are functional, the rest are read-only-zero
                    if (i < PMP_USABLE && !pmp_table[i].cfg.l)
                        pmp_table[i].cfg <= cfg_from_byte(csr_data_in[j*8 +: 8]);
                end
            end else if (int'(csr_sel_in) >= int'(CSR_PMPADDR0) &&
                         int'(csr_sel_in) <  int'(CSR_PMPADDR0) + PMP_ENTRIES) begin
                // Writing to pmpaddr
                automatic int i = int'(csr_sel_in) - int'(CSR_PMPADDR0);
                // Ignore write if unusable (read-only-zero entry), or this/following TOR entry is locked
                if (i < PMP_USABLE && !pmpaddr_write_ignored(i)) begin
                    pmp_table[i].addr       <= csr_data_in;
                end
            end
        end
    end
end else begin : gen_no_pmp_table
    assign pmp_table = '0;
end

// ============================================================
// CSR read
// ============================================================

// Decode selected CSR address
// Determine whether the selected CSR is implemented
logic csr_not_implemented;

always_comb begin : csr_read
    csr_not_implemented = 1'b0;
    case (selected_csr)
        // Set in block below
        CSR_PMPCFG0:  csr_out = 32'h0;
        CSR_PMPADDR0: csr_out = 32'h0;

        // Machine Information Registers
        CSR_MVENDORID:     csr_out = 32'h0;
        CSR_MARCHID:       csr_out = 32'h0;
        CSR_MIMPID:        csr_out = 32'h0;
        CSR_MHARTID:       csr_out = HART_ID;
        CSR_MCONFIGPTR:    csr_out = 32'h0;

        // Machine Trap Setup
        CSR_MSTATUS:       csr_out = csr.mstatus;
        // M and A bits are generated dynamically based on parameters.
        // When adding new extensions, set the corresponding MISA bits from config, unless always present. 
        //                                mx----zyxwvutsrqpon m                        lkjihgfedcb a
        CSR_MISA:          csr_out = {19'b0100000000010100000,{ENABLE_EXTENSION_M},11'b00010000000,{ENABLE_EXTENSION_A}};
        CSR_MEDELEG:       csr_out = csr.medeleg;
        CSR_MIDELEG:       csr_out = csr.mideleg;
        CSR_MIE:           csr_out = csr.mie;
        CSR_MTVEC:         csr_out = csr.mtvec;
        CSR_MCOUNTEREN:    csr_out = csr.mcounteren;
        CSR_MENVCFG:       csr_out = csr.menvcfg;
        CSR_MENVCFGH:      csr_out = csr.menvcfgh;
        CSR_MSTATUSH:      csr_out = 32'h0;

        // Machine Trap Handling
        CSR_MSCRATCH:      csr_out = csr.mscratch;
        CSR_MEPC:          csr_out = csr.mepc;
        CSR_MCAUSE:        csr_out = csr.mcause;
        CSR_MTVAL:         csr_out = csr.mtval;
        CSR_MIP:           csr_out = {20'b0, meip_in, 1'b0, seip_eff, 1'b0, mtip_in, 1'b0, stip_eff, 1'b0, msip_in, 1'b0, csr.ssip, 1'b0};

        // Machine Counter/Timers
        CSR_MCYCLE:        csr_out = csr.mcycle[31:0];
        CSR_MINSTRET:      csr_out = csr.minstret[31:0];
        CSR_MCYCLEH:       csr_out = csr.mcycle[63:32];
        CSR_MINSTRETH:     csr_out = csr.minstret[63:32];

        // Machine Counter Setup
        CSR_MCOUNTINHIBIT: csr_out = csr.mcountinhibit;

        // User/Supervisor Counter/Timer shadows (read-only)
        CSR_CYCLE:         csr_out = csr.mcycle[31:0];
        CSR_INSTRET:       csr_out = csr.minstret[31:0];
        CSR_CYCLEH:        csr_out = csr.mcycle[63:32];
        CSR_INSTRETH:      csr_out = csr.minstret[63:32];
        CSR_TIME:          csr_out = mtime_in[31:0];
        CSR_TIMEH:         csr_out = mtime_in[63:32];

        // Supervisor Trap Setup
        // sstatus is mstatus with M-mode-only bits (MIE[3], MPIE[7], MPP[12:11], MPRV[17]) zeroed
        CSR_SSTATUS:       csr_out = data_t'(csr.mstatus) & ~32'h0002_1888;
        CSR_SCOUNTEREN:    csr_out = csr.scounteren;
        CSR_SIE:           csr_out = csr.mie & 32'h0000_0222;  // S-mode bits: SEIE[9], STIE[5], SSIE[1]
        CSR_STVEC:         csr_out = csr.stvec;
        CSR_SENVCFG:       csr_out = csr.senvcfg;
        CSR_SSCRATCH:      csr_out = csr.sscratch;
        CSR_SEPC:          csr_out = csr.sepc;
        CSR_SCAUSE:        csr_out = csr.scause;
        CSR_STVAL:         csr_out = csr.stval;
        // S-mode visible interrupt pending bits only
        CSR_SIP:           csr_out = {22'b0, seip_eff, 3'b0, stip_eff, 3'b0, csr.ssip, 1'b0};

        // Supervisor Timer (Sstc)
        CSR_STIMECMP:      csr_out = csr.stimecmp;
        CSR_STIMECMPH:     csr_out = csr.stimecmph;

        // Supervisor Protection and Translation
        CSR_SATP:          csr_out = csr.satp;

        // Core Debug Registers
        CSR_DCSR:      begin csr_out = csr.dcsr;      csr_not_implemented = !debug_mode_active; end
        CSR_DPC:       begin csr_out = csr.dpc;       csr_not_implemented = !debug_mode_active; end
        CSR_DSCRATCH0: begin csr_out = csr.dscratch0; csr_not_implemented = !debug_mode_active; end
        CSR_DSCRATCH1: begin csr_out = csr.dscratch1; csr_not_implemented = !debug_mode_active; end

        default: begin
            csr_out             = 32'h0;
            csr_not_implemented = 1'b1;
        end
    endcase

    // Machine Memory Protection
    if (int'(selected_csr) >= int'(CSR_PMPCFG0) &&
        int'(selected_csr) <  int'(CSR_PMPCFG0) + PMP_ENTRIES/4) begin
        csr_out = ENFORCE_PMP ? pmpcfg_word(int'(selected_csr) - int'(CSR_PMPCFG0)) : 32'h0;
        csr_not_implemented = 1'b0;
    end else if (int'(selected_csr) >= int'(CSR_PMPADDR0) &&
                 int'(selected_csr) <  int'(CSR_PMPADDR0) + PMP_ENTRIES) begin
        csr_out = ENFORCE_PMP ? pmp_table[int'(selected_csr) - int'(CSR_PMPADDR0)].addr : 32'h0;
        csr_not_implemented = 1'b0;
    end
end : csr_read

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
    unique case (ir_buff.r.opcode)
        JALR: begin
            // Also detect misalignment on the commiting cycle of the instruction updating the source register.
            automatic addr_t jalr_base = (rd_sel_in != 0 && ir_buff.r.rs1 == rd_sel_in) ? rd_data_in : jump_base;
            automatic data_t jalr_imm = {{21{ir_buff.b[31]}}, ir_buff.b[30:20]};
            automatic addr_t target = (jalr_base + jalr_imm) & ~ 32'd1;
            target_misaligned = target[1] && instr_valid_buff;
            misaligned_target = target;
        end
        JAL: begin
            automatic data_t jal_imm = {{12{ir_buff.b[31]}}, ir_buff.b[19:12], ir_buff.b[20], ir_buff.b[30:21], 1'b0};
            automatic addr_t target = pc_in_buff + jal_imm;
            target_misaligned = target[1] && instr_valid_buff;
            misaligned_target = target;
        end
        default: begin
            target_misaligned = 1'b0;
            misaligned_target = '0;
        end
    endcase
end

// Compute the final target of a JAL/JALR.
// This is separate from the target_misaligned logic to avoid a combinatorial loop in trap detection.
always_comb begin
    if (!trap_out) begin
        addr_t jal_target_base;
        data_t jal_imm;
        jal_target_base = '0;
        jal_imm = '0;

        case (ir_buff.r.opcode)
            JALR: begin
                jal_ok_out = !target_misaligned;
                jal_target_base = (rd_sel_in != 0 && ir_buff.r.rs1 == rd_sel_in) ? rd_data_in : jump_base;
                jal_imm = {{21{ir_buff.b[31]}}, ir_buff.b[30:20]};  // I-type immediate
                jal_target = (jal_target_base + jal_imm) & ~32'h1;
            end
            JAL: begin
                jal_ok_out = !target_misaligned;
                jal_imm = {{12{ir_buff.b[31]}}, ir_buff.b[19:12], ir_buff.b[20], ir_buff.b[30:21], 1'b0};  // J-type immediate
                jal_target = pc_in_buff + jal_imm;
            end
            default: begin
                jal_ok_out = 1'b0;
                jal_target = '0;
            end
        endcase
    end else begin
        jal_ok_out = 1'b0;
        jal_target = '0;
    end
end

// ============================================================
// MMU outputs
// ============================================================

assign satp_out = csr.satp;
assign sum_out  = csr.mstatus.sum;
assign mxr_out  = csr.mstatus.mxr;
assign mode_out = r_current_mode;
assign data_mode_out = (!debug_mode_active && r_current_mode == M_MODE && csr.mstatus.mprv)
                       ? csr.mstatus.mpp : r_current_mode;

// ============================================================
// Instruction decoding
// ============================================================

friscv_id_decoder #(
    .ENABLE_EXTENSION_A ( ENABLE_EXTENSION_A ),
    .ENABLE_MUL         ( ENABLE_MUL         ),
    .ENABLE_DIV         ( ENABLE_DIV         )
) friscv_id_decoder (
    .ir_in                  ( ir_buff             ),
    .mode_in                ( r_current_mode      ),
    .dbg_active_in          ( debug_mode_active   ),
    .tvm_in                 ( csr.mstatus.tvm     ),
    .csr_not_implemented_in ( csr_not_implemented ),
    .mcounteren_in          ( csr.mcounteren      ),
    .scounteren_in          ( csr.scounteren      ),
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

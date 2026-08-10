// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements trap detection, prioritization and commit for the FRISC-V core. It is responsible for:
 * - Owning the hart state: current privilege mode, debug mode, and the single-step state machine
 * - Detecting and prioritizing interrupts and exceptions from all pipeline stages, with delegation to S-mode
 * - Deciding when a trap can commit (no CSR/GPR/memory hazards in flight) and signaling the trapping stage
 * - Resolving the trap vector, return address, cause code, EPC and TVAL
 * - Committing MRET/SRET/DRET and debug mode entry/exit
 *
 * The controller does not hold any architectural CSR state. It reads CSR values from friscv_csr_file and,
 * when a trap or return commits, issues a command bundle (trap_csr_en_out, trap_to_*_out, trap_epc/cause/tval,
 * xret_commit_out) that the CSR file executes without any trap knowledge of its own.
 */

module friscv_trap_controller import friscv_pkg::*, friscv_mem_pkg::*; #(
    parameter int unsigned DM_BASE = 32'h0000_0000,
    parameter int unsigned DM_HALT_OFFSET = 32'h800,
    parameter int unsigned DM_EXC_OFFSET  = 32'h810,

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

    // Stage control signals
    input  logic      flush_in,
    input  logic      stage_stall_in,

    // Buffered instruction and fetch state from the ID input capture
    input  instr_op_t ir_in,
    input  addr_t     pc_in,
    input  logic      instr_valid_in,
    input  mode_e     pc_mode_in,
    input  logic      inst_fault_buff_in,
    input  addr_t     fault_addr_buff_in,
    input  logic      inst_err_buff_in,
    input  logic      inst_pmp_fault_buff_in,

    // Unbuffered fetch fault inputs, used to release if_trap_inhibit
    input  logic      inst_fault_in,
    input  logic      inst_err_in,
    input  logic      inst_pmp_fault_in,

    // Decoder outputs for ID-originated exceptions
    input  logic      illegal_inst_in,
    input  logic      ecall_active_in,
    input  logic      ebreak_active_in,
    input  logic      target_misaligned_in,
    input  addr_t     misaligned_target_in,
    input  logic      mret_en_in,
    input  logic      sret_en_in,

    // EX stage trap
    input  ex_trap_e  ex_trap_in,
    input  addr_t     ex_trap_pc_in,
    input  addr_t     ex_trap_va_in,
    input  mode_e     ex_trap_mode_in,
    output logic      ex_trap_commit_out,

    // Data memory page fault
    input  mem_trap_e mem_trap_in,
    input  addr_t     mem_trap_pc_in,
    input  addr_t     mem_trap_va_in,
    input  mode_e     mem_trap_mode_in,
    output logic      mem_trap_commit_out,

    // Pipeline hazard visibility
    input  reg_addr_t ex_rd_sel_in,
    input  reg_addr_t mem_rd_sel_in,
    input  reg_addr_t wb_rd_sel_in,
    input  logic      ex_muldiv_active_in,
    input  logic      ex_csr_en_in,
    input  logic      mem_csr_en_in,
    input  logic      wb_csr_en_in,
    input  logic      ex_mem_inflight_in,
    input  logic      mem_mem_inflight_in,

    // CSR state from the CSR file
    input  mstatus_t  mstatus_in,
    input  addr_t     mtvec_in,
    input  addr_t     stvec_in,
    input  data_t     medeleg_in,
    input  data_t     mideleg_in,
    input  data_t     mie_in,
    input  dcsr_t     dcsr_in,
    input  addr_t     dpc_in,
    input  addr_t     sepc_in,
    input  addr_t     mepc_in,
    input  logic      ssip_in,
    input  logic      stip_eff_in,
    input  logic      seip_eff_in,

    // Outputs and inputs for handling interrupts
    output addr_t     tvec_out,          // Resolved mtvec or stvec
    output addr_t     epc_out,           // Resolved mepc or sepc
    output logic      trap_out,
    output logic      trap_pending_out,
    output logic      ret_out,           // Active for both mret and sret
    input  logic      ret_commit_in,

    // Hart state
    output mode_e     mode_out,
    output logic      debug_mode_out,

    // Trap commit commands to the CSR file
    output logic       trap_csr_en_out,   // Capture trap state into CSRs this cycle
    output logic       trap_to_debug_out, // Debug entry, write dpc/dcsr instead of xepc/xcause
    output logic       trap_to_s_out,     // Delegated, write sepc/scause/stval instead of M equivalents
    output addr_t      trap_epc_out,
    output data_t      trap_cause_out,
    output data_t      trap_tval_out,
    output mode_e      trap_mode_out,     // Privilege mode the trap originated from (for mpp/spp)
    output logic [2:0] dcsr_cause_out,    // Debug entry cause for dcsr.cause
    output logic       mret_commit_out,
    output logic       sret_commit_out,
    output logic       dret_commit_out
);

// Current privilege mode of the hart.
mode_e r_current_mode;
logic  debug_mode_active;

assign mode_out       = r_current_mode;
assign debug_mode_out = debug_mode_active;

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
assign id_dispatch = instr_valid_in && !stage_stall_in && !flush_in
                     && !trap_out && !trap_pending_out;

// ============================================================
// Trap detection
// ============================================================

logic dcsr_ebreak_eff;
always_comb case (r_current_mode)
    M_MODE:  dcsr_ebreak_eff = dcsr_in.ebreakm;
    H_MODE:  dcsr_ebreak_eff = dcsr_in.ebreakm;
    S_MODE:  dcsr_ebreak_eff = dcsr_in.ebreaks;
    U_MODE:  dcsr_ebreak_eff = dcsr_in.ebreaku;
    default: dcsr_ebreak_eff = dcsr_in.ebreaku;
endcase

logic r_mret_inhibit;

// Check if interrupt is safe to execute - safe if
//  1) Not returning from a previous interrupt,
//  2) Not executing a branch and
//  3) Not in the middle of a fetch
// This is to prevent a taken interrupt killing valid instructions, or ret being skipped.
// A previous interrupt must safely exit before taking the next interrupt.
logic interrupt_safe;
assign interrupt_safe = !r_mret_inhibit && !branch_ok_in && instr_valid_in && !debug_mode_active;

// A synchronous exception is safe only if the buffer holds a valid instruciton,
// and a redirect is not being processed that would kill the trapping instruction anyway (branch_ok_in).
logic exception_safe;
assign exception_safe = !branch_ok_in && instr_valid_in;

// ============================================================
// Interrupt detection
// ============================================================

// m_interrupt_active if an interrupt to M-mode is pending and not masked or delegated.
// This interrupt will be taken as soon as it is safe to do so.
logic m_interrupt_active;
assign m_interrupt_active = interrupt_safe &&
                            r_step == STEP_OFF &&
                            (mstatus_in.mie || r_current_mode != M_MODE) &&
                            ((msip_in && mie_in[3]) ||
                             (mtip_in && mie_in[7]) ||
                             (meip_in && mie_in[11]));

// s_interrupt_active if an interrupt to S-mode is pending and not masked, delegated, or overridden by an M-mode interrupt.
// This interrupt will be taken as soon as it is safe to do so and there are no M-mode interrupts.
logic s_interrupt_active;
assign s_interrupt_active = interrupt_safe &&
                            r_step == STEP_OFF &&
                            (r_current_mode != M_MODE) &&
                            (mstatus_in.sie || r_current_mode == U_MODE) &&
                            ((ssip_in     && mie_in[1] && mideleg_in[1]) ||
                             (stip_eff_in && mie_in[5] && mideleg_in[5]) ||
                             (seip_eff_in && mie_in[9] && mideleg_in[9]));

// An interrupt is active (pending or being taken) if either an M-mode or S-mode interrupt is active.
// All required gating is done by m_interrupt_active and s_interrupt_active.
logic interrupt_active;
assign interrupt_active = m_interrupt_active || s_interrupt_active;

// ============================================================
// Exception detection
// ============================================================

// IF stage traps can be page faults or access faults.
// These are propagated to ID with a cycle of latency and come with the relevant faulting instruction.
typedef enum logic [1:0] {
    IF_TRAP_NONE,
    IF_TRAP_FAULT,
    IF_TRAP_ACCESS
} if_trap_e;

if_trap_e if_trap;
assign if_trap = inst_fault_buff_in                         ? IF_TRAP_FAULT  :
                 inst_err_buff_in || inst_pmp_fault_buff_in ? IF_TRAP_ACCESS :
                                                              IF_TRAP_NONE;

// An IF exception is not taken if there is a branch redirect in-flight that would kill the trapping instruction anyway, or if the trap is currently inhibited.
logic if_trap_inhibit;
logic is_if_trap;
assign is_if_trap = (if_trap != IF_TRAP_NONE) && !if_trap_inhibit && !branch_ok_in;

logic is_mem_trap;
assign is_mem_trap = mem_trap_in != MEM_TRAP_NONE;

logic is_ex_trap;
assign is_ex_trap = ex_trap_in != EX_TRAP_NONE;

logic exception_other;
assign exception_other = is_if_trap || is_ex_trap || is_mem_trap;

// Enter debug on ebreak if it is safe to redirect, the current mode allows it (dcsr.ebreakm/s/u),
// not currently in debug mode, and no exception from an older instruction is being taken.
logic ebreak_to_debug;
assign ebreak_to_debug = exception_safe && ebreak_active_in && dcsr_ebreak_eff
                         && !debug_mode_active && !exception_other;

// The exception is originating from ID if it is ecall, ebreak, illegal instruction, or jump target misaligned.
logic is_id_trap;
assign is_id_trap = exception_safe &&
                    (ecall_active_in  ||
                     (ebreak_active_in && !ebreak_to_debug) ||
                     illegal_inst_in  ||
                     target_misaligned_in);

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

// ============================================================
// Taking a trap
// ============================================================

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
                           (wb_rd_sel_in  != 5'd0));

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
assign mret_active = (ir_in.r.opcode == SYSTEM) && (ir_in.r.funct3 == 3'b000) && (ir_in.b[31:20] == 12'b001100000010);
assign sret_active = (ir_in.r.opcode == SYSTEM) && (ir_in.r.funct3 == 3'b000) && (ir_in.b[31:20] == 12'b000100000010);
assign dret_active = (ir_in.r.opcode == SYSTEM) && (ir_in.r.funct3 == 3'b000) && (ir_in.b[31:20] == 12'b011110110010);

// Signal to the control logic that a return instruction is being taken.
assign ret_out = (mret_active || sret_active || dret_active) && !illegal_inst_in;

assign mret_commit_out = ret_commit_in && mret_active;
assign sret_commit_out = ret_commit_in && sret_active;
assign dret_commit_out = ret_commit_in && dret_active;

// ============================================================
// Generate cause code
// ============================================================

// Take the exception source decoded above and generate the corresponding exception cause code.
logic [4:0] exception_cause_code;
always_comb begin
    exception_cause_code = 5'd0;                   // No exception by default
    case (trap_src)
        TRAP_SRC_IF:
            if (if_trap == IF_TRAP_FAULT)
                exception_cause_code = 5'd12;      // Instruction page fault
            else if (if_trap == IF_TRAP_ACCESS)
                exception_cause_code = 5'd1;       // Instruction access fault
            else
                exception_cause_code = 5'd0;       // No exception
        TRAP_SRC_ID:
            if (ecall_active_in)
                if (r_current_mode == U_MODE)
                    exception_cause_code = 5'd8;   // Environment call from U-mode
                else if (r_current_mode == S_MODE)
                    exception_cause_code = 5'd9;   // Environment call from S-mode
                else
                    exception_cause_code = 5'd11;  // Environment call from M-mode
            else if (ebreak_active_in)
                exception_cause_code = 5'd3;       // Breakpoint
            else if (illegal_inst_in)
                exception_cause_code = 5'd2;       // Illegal instruction
            else if (target_misaligned_in)
                exception_cause_code = 5'd0;       // Instruction address misaligned
        TRAP_SRC_EX:
            exception_cause_code = 5'd0;           // No exception or Instruction address misaligned
        TRAP_SRC_MEM:
            case (mem_trap_in)
                MEM_TRAP_LOAD_MISALIGNED:  exception_cause_code = 5'd4;   // Load address misaligned
                MEM_TRAP_LOAD_ACCESS:      exception_cause_code = 5'd5;   // Load access fault
                MEM_TRAP_STORE_MISALIGNED: exception_cause_code = 5'd6;   // Store/AMO address misaligned
                MEM_TRAP_STORE_ACCESS:     exception_cause_code = 5'd7;   // Store/AMO access fault
                MEM_TRAP_LOAD:             exception_cause_code = 5'd13;  // Load page fault
                MEM_TRAP_STORE:            exception_cause_code = 5'd15;  // Store/AMO page fault
                MEM_TRAP_NONE:             exception_cause_code = 5'd0;   // No exception
                default:                   exception_cause_code = 5'd0;   // No exception
            endcase
        TRAP_SRC_NONE: exception_cause_code = 5'd0;
        default:       exception_cause_code = 5'd0;
    endcase
end

assign halt_out = (ENABLE_HALT_ON_ENTER_EBREAK && ebreak_active_in) ||
                  (ENABLE_HALT_ON_RET_FROM_EBREAK && r_in_ebreak_handler && (mret_en_in || sret_en_in));

// A trap is delegated to S-mode when:
//   - Not already in M-mode (traps never transition to less-privileged mode)
//   - No M-mode interrupt is active (M-mode interrupts take priority over S-mode)
//   - s_interrupt_active (already checks mideleg bits), or
//   - exception cause bit is set in medeleg
logic is_delegated;

mode_e trap_mode;
always_comb begin
    case (trap_src)
        TRAP_SRC_IF:   trap_mode = pc_mode_in;
        TRAP_SRC_ID:   trap_mode = r_current_mode;
        TRAP_SRC_EX:   trap_mode = ex_trap_mode_in;
        TRAP_SRC_MEM:  trap_mode = mem_trap_mode_in;
        TRAP_SRC_NONE: trap_mode = r_current_mode;
        default:       trap_mode = r_current_mode;
    endcase
end

assign is_delegated = (trap_mode != M_MODE) &&
                      !m_interrupt_active &&
                      (s_interrupt_active || (exception_active && medeleg_in[exception_cause_code]));

logic trap_to_s_mode;
assign trap_to_s_mode = trap_out && is_delegated;

// Interrupt cause code for vectored tvec offset
logic [31:0] current_cause;
always_comb begin
    if (meip_in && mie_in[11])
        current_cause = 32'd11;
    else if (mtip_in && mie_in[7])
        current_cause = 32'd7;
    else if (msip_in && mie_in[3])
        current_cause = 32'd3;
    else if (seip_eff_in && mie_in[9] && mideleg_in[9])
        current_cause = 32'd9;
    else if (stip_eff_in && mie_in[5] && mideleg_in[5])
        current_cause = 32'd5;
    else if (ssip_in && mie_in[1] && mideleg_in[1])
        current_cause = 32'd1;
    else
        current_cause = 32'd0;
end

// ============================================================
// Trap EPC and TVAL resolution
// ============================================================

// Return address used by mret/sret
assign epc_out = dret_active ? dpc_in  :
                 sret_active ? sepc_in :
                               mepc_in;

// Trap vector, resolved to correct mode with vectored mode
assign tvec_out = debug_mode_active && exception_active
                  ? ((trap_src == TRAP_SRC_ID && ebreak_active_in)
                     ? DM_BASE + DM_HALT_OFFSET
                     : DM_BASE + DM_EXC_OFFSET)
                  : debug_entry
                  ? DM_BASE + DM_HALT_OFFSET
                  : trap_to_s_mode
                  ? ((stvec_in[1:0] == 2'b01 && interrupt_active)
                     ? {stvec_in[31:2], 2'b0} + {current_cause[29:0], 2'b0}  // vectored S-mode trap
                     : {stvec_in[31:2], 2'b0})                               // direct S-mode trap
                  : ((mtvec_in[1:0] == 2'b01 && interrupt_active)
                     ? {mtvec_in[31:2], 2'b0} + {current_cause[29:0], 2'b0}  // vectored M-mode trap
                     : {mtvec_in[31:2], 2'b0});                              // direct M-mode trap

addr_t trap_epc;
always_comb begin
    case (trap_src)
        TRAP_SRC_IF:   trap_epc = pc_in;
        TRAP_SRC_ID:   trap_epc = pc_in;
        TRAP_SRC_EX:   trap_epc = ex_trap_pc_in;
        TRAP_SRC_MEM:  trap_epc = mem_trap_pc_in;
        TRAP_SRC_NONE: trap_epc = pc_in;
        default:       trap_epc = pc_in;
    endcase
end

addr_t trap_tval;
always_comb begin
    case (trap_src)
        TRAP_SRC_IF:  trap_tval = (if_trap == IF_TRAP_ACCESS) ? '0 : fault_addr_buff_in;
        TRAP_SRC_ID:  trap_tval = illegal_inst_in      ? ir_in.b              :
                                  target_misaligned_in ? misaligned_target_in : '0;
        TRAP_SRC_EX:  trap_tval = ex_trap_va_in;
        TRAP_SRC_MEM:
            if (mem_trap_in == MEM_TRAP_LOAD_ACCESS || mem_trap_in == MEM_TRAP_STORE_ACCESS)
                trap_tval = '0;
            else
                trap_tval = mem_trap_va_in;
        TRAP_SRC_NONE: trap_tval = '0;
        default:       trap_tval = '0;
    endcase
end

// ============================================================
// Trap commit commands to the CSR file
// ============================================================

// Interrupt causes take priority over exception causes, matching the tvec resolution above.
assign trap_csr_en_out   = trap_out && !debug_mode_active;
assign trap_to_debug_out = debug_entry;
assign trap_to_s_out     = is_delegated;
assign trap_epc_out      = trap_epc;
assign trap_cause_out    = interrupt_active ? {1'b1, current_cause[30:0]}
                                            : data_t'(exception_cause_code);
assign trap_tval_out     = trap_tval;
assign trap_mode_out     = trap_mode;
assign dcsr_cause_out    = dbg_req_in      ? 3'd3 : // haltreq
                           ebreak_to_debug ? 3'd1 : // ebreak
                                             3'd4;  // step

// ============================================================
// Hart state update
// ============================================================

always_ff @(posedge clk_in or negedge rst_n_in) begin
    if (!rst_n_in) begin
        r_current_mode      <= M_MODE;
        debug_mode_active   <= 1'b0;
        r_mret_inhibit      <= 1'b0;
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
            trap_seen      <= 1'b1;
            r_mret_inhibit <= 1'b0;

            if (trap_src == TRAP_SRC_ID && ebreak_active_in)
                r_in_ebreak_handler <= 1'b1;

            // A trap taken while in debug mode redirects only, without any state update
            if (!debug_mode_active) begin
                if (debug_entry) begin
                    debug_mode_active <= 1'b1;
                    r_current_mode    <= M_MODE;
                    r_step            <= STEP_OFF;
                end else if (trap_to_s_mode) begin
                    r_current_mode <= S_MODE;
                end else begin
                    // Non-delegated trap: enter M-mode
                    r_current_mode <= M_MODE;
                end
            end

        end else if (ret_commit_in && dret_active) begin
            r_mret_inhibit    <= 1'b1;
            debug_mode_active <= 1'b0;
            r_current_mode    <= dcsr_in.prv;
            r_step            <= dcsr_in.step ? STEP_ARMED : STEP_OFF;

        end else if (ret_commit_in && sret_active) begin
            r_mret_inhibit <= 1'b1;
            r_current_mode <= mstatus_in.spp ? S_MODE : U_MODE;

        end else if (ret_commit_in && mret_active) begin
            r_mret_inhibit <= 1'b1;
            r_current_mode <= mstatus_in.mpp;
        end
    end
end

endmodule

// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements trap detection, prioritization and commit for the FRISC-V core.
 * It is responsible for:
 * - Owning the hart state: current privilege mode, debug mode,
 *   and the single-step state machine
 * - Detecting and prioritizing interrupts and exceptions from all pipeline stages,
 *   with delegation to S-mode
 * - Deciding when a trap can commit (no CSR/GPR/memory hazards in flight) and
 *   signaling the trapping stage
 * - Resolving the trap vector, return address, cause code, EPC and TVAL
 * - Committing MRET/SRET/DRET and debug mode entry/exit
 *
 * The controller does not hold any architectural CSR state.
 * It reads CSR values from friscv_csr_file and, when a trap or return commits, issues a
 * command bundle (trap_csr_en_out, trap_to_*_out, trap_epc/cause/tval,
 * xret_commit_out) that the CSR file executes without any trap knowledge of its own.
 */

module friscv_trap_controller
    import friscv_pkg::*;
#(
    parameter int unsigned DmBase       = 32'h0000_0000,
    parameter int unsigned DmHaltOffset = 32'h800,
    parameter int unsigned DmExcOffset  = 32'h810,

    // If enabled, entering an EBREAK instruction will halt the core until reset
    parameter bit HaltOnEnterEbreak = 0,
    // If enabled, the first MRET or SRET after entering an EBREAK handler will halt until reset
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

    // Stage control signals
    input  logic      flush_i,
    input  logic      stall_i,

    // Buffered instruction and fetch state from the ID input capture
    input  instr_op_t ir_i,
    input  addr_t     pc_i,
    input  logic      instr_valid_i,
    input  mode_e     pc_mode_i,
    input  logic      inst_fault_q_i,
    input  addr_t     fault_addr_q_i,
    input  logic      inst_err_q_i,
    input  logic      inst_pmp_fault_q_i,

    // Unbuffered fetch fault inputs, used to release if_trap_inhibit
    input  logic      inst_fault_i,
    input  logic      inst_err_i,
    input  logic      inst_pmp_fault_i,

    // Decoder outputs for ID-originated exceptions
    input  logic      illegal_inst_i,
    input  logic      ecall_active_i,
    input  logic      ebreak_active_i,
    input  logic      target_misaligned_i,
    input  addr_t     misaligned_target_i,
    input  logic      mret_en_i,
    input  logic      sret_en_i,

    // EX stage trap
    input  ex_trap_e  ex_trap_i,
    input  addr_t     ex_trap_pc_i,
    input  addr_t     ex_trap_va_i,
    input  mode_e     ex_trap_mode_i,
    output logic      ex_trap_commit_o,

    // Data memory page fault
    input  mem_trap_e mem_trap_i,
    input  addr_t     mem_trap_pc_i,
    input  addr_t     mem_trap_va_i,
    input  mode_e     mem_trap_mode_i,
    output logic      mem_trap_commit_o,

    // Pipeline hazard visibility
    input  reg_addr_t ex_rd_sel_i,
    input  reg_addr_t mem_rd_sel_i,
    input  reg_addr_t wb_rd_sel_i,
    input  logic      ex_muldiv_active_i,
    input  logic      ex_csr_en_i,
    input  logic      mem_csr_en_i,
    input  logic      wb_csr_en_i,
    input  logic      ex_mem_inflight_i,
    input  logic      mem_mem_inflight_i,

    // CSR state from the CSR file
    input  mstatus_t  mstatus_i,
    input  addr_t     mtvec_i,
    input  addr_t     stvec_i,
    input  data_t     medeleg_i,
    input  data_t     mideleg_i,
    input  data_t     mie_i,
    input  dcsr_t     dcsr_i,
    input  addr_t     dpc_i,
    input  addr_t     sepc_i,
    input  addr_t     mepc_i,
    input  logic      ssip_i,
    input  logic      stip_eff_i,
    input  logic      seip_eff_i,

    // Outputs and inputs for handling interrupts
    output addr_t     tvec_o,          // Resolved mtvec or stvec
    output addr_t     epc_o,           // Resolved mepc or sepc
    output logic      trap_o,
    output logic      trap_pending_o,
    output logic      ret_o,           // Active for both mret and sret
    input  logic      ret_commit_i,

    // Hart state
    output mode_e     mode_o,
    output logic      debug_mode_o,

    // Trap commit commands to the CSR file
    output logic       trap_csr_en_o,   // Capture trap state into CSRs this cycle
    output logic       trap_to_debug_o, // Debug entry, write dpc/dcsr instead of xepc/xcause
    output logic       trap_to_s_o,     // Delegated, write sepc/... instead of mepc/...
    output addr_t      trap_epc_o,
    output data_t      trap_cause_o,
    output data_t      trap_tval_o,
    output mode_e      trap_mode_o,     // Privilege mode the trap originated from (for mpp/spp)
    output logic [2:0] dcsr_cause_o,    // Debug entry cause for dcsr.cause
    output logic       mret_commit_o,
    output logic       sret_commit_o,
    output logic       dret_commit_o
);

// Current privilege mode of the hart.
mode_e current_mode;
logic  debug_mode_active;

assign mode_o       = current_mode;
assign debug_mode_o = debug_mode_active;

/////////////////////////////
// Single Step Debug Logic //
/////////////////////////////

typedef enum logic [1:0] {
    StepOff,
    StepArmed,
    StepFire
} step_e;

step_e step;

// An instruction leaves ID this cycle
logic id_dispatch;
assign id_dispatch = instr_valid_i && !stall_i && !flush_i && !trap_o && !trap_pending_o;

////////////////////
// Trap Detection //
////////////////////

logic dcsr_ebreak_eff;
always_comb unique case (current_mode)
    M_MODE:  dcsr_ebreak_eff = dcsr_i.ebreakm;
    H_MODE:  dcsr_ebreak_eff = dcsr_i.ebreakm;
    S_MODE:  dcsr_ebreak_eff = dcsr_i.ebreaks;
    U_MODE:  dcsr_ebreak_eff = dcsr_i.ebreaku;
    default: dcsr_ebreak_eff = dcsr_i.ebreaku;
endcase

logic mret_inhibit;
logic mret_active, sret_active, dret_active;

// Check if interrupt is safe to execute - safe if
//  1) Not returning from a previous interrupt,
//  2) Not executing a branch and
//  3) Not in the middle of a fetch
// This is to prevent a taken interrupt killing valid instructions, or ret being skipped.
// A previous interrupt must safely exit before taking the next interrupt.
logic interrupt_safe;
assign interrupt_safe = !mret_inhibit &&
                        !(mret_active || sret_active || dret_active) &&
                        !branch_ok_i && instr_valid_i && !debug_mode_active;

// A synchronous exception is safe only if the buffer holds a valid instruciton,
// and a redirect is not being processed that would kill the trapping instruction anyway.
logic exception_safe;
assign exception_safe = !branch_ok_i && instr_valid_i;

/////////////////////////
// Interrupt Detection //
/////////////////////////

// m_interrupt_active if an interrupt to M-mode is pending and not masked or delegated.
// This interrupt will be taken as soon as it is safe to do so.
logic m_interrupt_active;
assign m_interrupt_active = interrupt_safe &&
                            step == StepOff &&
                            (mstatus_i.mie || current_mode != M_MODE) &&
                            ((msip_i && mie_i[3]) ||
                             (mtip_i && mie_i[7]) ||
                             (meip_i && mie_i[11]));

// s_interrupt_active if an interrupt to S-mode is pending and not masked, delegated,
// or overridden by an M-mode interrupt. This interrupt will be taken as soon as
// it is safe to do so and there are no M-mode interrupts.
logic s_interrupt_active;
assign s_interrupt_active = interrupt_safe &&
                            step == StepOff &&
                            (current_mode != M_MODE) &&
                            (mstatus_i.sie || current_mode == U_MODE) &&
                            ((ssip_i     && mie_i[1] && mideleg_i[1]) ||
                             (stip_eff_i && mie_i[5] && mideleg_i[5]) ||
                             (seip_eff_i && mie_i[9] && mideleg_i[9]));

// An interrupt is active (pending or taken) if either an M-mode or S-mode interrupt is active.
// All required gating is done by m_interrupt_active and s_interrupt_active.
logic interrupt_active;
assign interrupt_active = m_interrupt_active || s_interrupt_active;

/////////////////////////
// Exception Detection //
/////////////////////////

// IF stage traps can be page faults or access faults.
// These are propagated to ID with a cycle of latency and come with the faulting instruction.
typedef enum logic [1:0] {
    IF_TRAP_NONE,
    IF_TRAP_FAULT,
    IF_TRAP_ACCESS
} if_trap_e;

if_trap_e if_trap;
assign if_trap = inst_fault_q_i                     ? IF_TRAP_FAULT  :
                 inst_err_q_i || inst_pmp_fault_q_i ? IF_TRAP_ACCESS :
                                                      IF_TRAP_NONE;

// An IF exception is not taken if there is a branch redirect in-flight that
// would kill the trapping instruction anyway, or if the trap is currently inhibited.
logic if_trap_inhibit;
logic is_if_trap;
assign is_if_trap = (if_trap != IF_TRAP_NONE) && !if_trap_inhibit && !branch_ok_i;

logic is_mem_trap;
assign is_mem_trap = mem_trap_i != MEM_TRAP_NONE;

logic is_ex_trap;
assign is_ex_trap = ex_trap_i != EX_TRAP_NONE;

logic exception_other;
assign exception_other = is_if_trap || is_ex_trap || is_mem_trap;

// Enter debug on ebreak if it is safe to redirect, the current mode allows it (dcsr.ebreakm/s/u),
// not currently in debug mode, and no exception from an older instruction is being taken.
logic ebreak_to_debug;
assign ebreak_to_debug = exception_safe &&
                         ebreak_active_i &&
                         dcsr_ebreak_eff &&
                         !debug_mode_active &&
                         !exception_other;

// The exception is originating from ID if it is ecall, ebreak,
// illegal instruction, or jump target misaligned.
logic is_id_trap;
assign is_id_trap = exception_safe &&
                    (ecall_active_i  ||
                     (ebreak_active_i && !ebreak_to_debug) ||
                     illegal_inst_i  ||
                     target_misaligned_i);

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
assign debug_halt_entry = !debug_mode_active &&
                          interrupt_safe &&
                          (dbg_req_i || (step == StepFire));

logic debug_entry;
assign debug_entry = ebreak_to_debug || (debug_halt_entry && !exception_active);

///////////////////
// Taking a Trap //
///////////////////

// Trap RAW hazard - a CSR write in EX or MEM might update mtvec/mstatus/mepc before the
// trap fires. Suppress the effective trap (flush + CSR state write) until the pipeline
// is clear. trap_pending_out lets pipeline_control stall so the instruction is not lost
// from ir_q while waiting.
logic trap_raw, trap_csr_hazard;
logic trap_gpr_hazard;
assign trap_raw         = interrupt_active || exception_active || debug_entry;
assign trap_csr_hazard  = trap_raw && (ex_csr_en_i || mem_csr_en_i || wb_csr_en_i);
assign trap_gpr_hazard  = trap_raw &&
                          ((ex_rd_sel_i  != 5'd0) ||
                           (mem_rd_sel_i != 5'd0) ||
                           (wb_rd_sel_i  != 5'd0));

// Flag to not re-take an already taken trap.
logic trap_seen;

// An incoming trap has a pipeline hazard if
//  1) there is a memory instruction in the pipeline or
//  2) a dispatched instruction will write back to a register or
//  3) an iterative multiply/divide operation is still active.
// These must commit before taking a trap.
logic trap_pipe_hazard;
assign trap_pipe_hazard = trap_raw &&
                          (ex_mem_inflight_i || mem_mem_inflight_i ||
                           ex_muldiv_active_i || trap_gpr_hazard);
assign trap_o           = trap_raw && !trap_seen && !trap_csr_hazard && !trap_pipe_hazard;
assign trap_pending_o   = trap_raw && !trap_seen && (trap_csr_hazard || trap_pipe_hazard);

// Signal the EX or MEM stage that their trap is being taken, so they can kill their instructions.
assign ex_trap_commit_o  = trap_o && (trap_src == TRAP_SRC_EX || trap_src == TRAP_SRC_MEM);
assign mem_trap_commit_o = trap_o && (trap_src == TRAP_SRC_MEM);

// MRET and SRET are detected outside the main decoder to avoid a loop and improve timing.
assign mret_active = (ir_i.r.opcode == SYSTEM) &&
                     (ir_i.r.funct3 == 3'b000) &&
                     (ir_i.b[31:20] == 12'b001100000010);
assign sret_active = (ir_i.r.opcode == SYSTEM) &&
                     (ir_i.r.funct3 == 3'b000) &&
                     (ir_i.b[31:20] == 12'b000100000010);
assign dret_active = (ir_i.r.opcode == SYSTEM) &&
                     (ir_i.r.funct3 == 3'b000) &&
                     (ir_i.b[31:20] == 12'b011110110010);

// Signal to the control logic that a return instruction is being taken.
assign ret_o = (mret_active || sret_active || dret_active) && !illegal_inst_i;

assign mret_commit_o = ret_commit_i && mret_active;
assign sret_commit_o = ret_commit_i && sret_active;
assign dret_commit_o = ret_commit_i && dret_active;

/////////////////////////
// Generate Cause Code //
/////////////////////////

// Take the exception source decoded above and generate the corresponding exception cause code.
logic [4:0] exception_cause_code;
always_comb begin
    unique case (trap_src)
        TRAP_SRC_IF: unique case (if_trap)
            // Instruction page fault
            IF_TRAP_FAULT:  exception_cause_code = 5'd12;
            // Instruction access fault
            IF_TRAP_ACCESS: exception_cause_code = 5'd1;
            IF_TRAP_NONE:   exception_cause_code = 5'd0;
            default:        exception_cause_code = 5'd0;
        endcase
        TRAP_SRC_ID:
            if (ecall_active_i) unique case (current_mode)
                // Environment call from U-mode
                U_MODE: exception_cause_code = 5'd8;
                // Environment call from S-mode
                S_MODE: exception_cause_code = 5'd9;
                // Environment call from M-mode
                M_MODE: exception_cause_code = 5'd11;
                H_MODE: exception_cause_code = 5'd11;
                default: exception_cause_code = 5'd11;
            endcase
            // Breakpoint
            else if (ebreak_active_i)     exception_cause_code = 5'd3;
            // Illegal instruction
            else if (illegal_inst_i)      exception_cause_code = 5'd2;
            // Instruction address misaligned
            else if (target_misaligned_i) exception_cause_code = 5'd0;
            else                          exception_cause_code = 5'd0;
        // Instruction address misaligned
        TRAP_SRC_EX: exception_cause_code = 5'd0;
        TRAP_SRC_MEM: unique case (mem_trap_i)
            // Load address misaligned
            MEM_TRAP_LOAD_MISALIGNED:  exception_cause_code = 5'd4;
            // Load access fault
            MEM_TRAP_LOAD_ACCESS:      exception_cause_code = 5'd5;
            // Store/AMO address misaligned
            MEM_TRAP_STORE_MISALIGNED: exception_cause_code = 5'd6;
            // Store/AMO access fault
            MEM_TRAP_STORE_ACCESS:     exception_cause_code = 5'd7;
            // Load page fault
            MEM_TRAP_LOAD:             exception_cause_code = 5'd13;
            // Store/AMO page fault
            MEM_TRAP_STORE:            exception_cause_code = 5'd15;
            MEM_TRAP_NONE:             exception_cause_code = 5'd0;
            default:                   exception_cause_code = 5'd0;
        endcase
        TRAP_SRC_NONE: exception_cause_code = 5'd0;
        // No exception by default
        default: exception_cause_code = 5'd0;
    endcase
end

logic in_ebreak_handler;
assign halt_o = (HaltOnEnterEbreak && ebreak_active_i) ||
                (HaltOnRetFromEbreak && in_ebreak_handler && (mret_en_i || sret_en_i));

// A trap is delegated to S-mode when:
//   - Not already in M-mode (traps never transition to less-privileged mode)
//   - No M-mode interrupt is active (M-mode interrupts take priority over S-mode)
//   - s_interrupt_active (already checks mideleg bits), or
//   - exception cause bit is set in medeleg
logic is_delegated;

mode_e trap_mode;
always_comb begin
    unique case (trap_src)
        TRAP_SRC_IF:   trap_mode = pc_mode_i;
        TRAP_SRC_ID:   trap_mode = current_mode;
        TRAP_SRC_EX:   trap_mode = ex_trap_mode_i;
        TRAP_SRC_MEM:  trap_mode = mem_trap_mode_i;
        TRAP_SRC_NONE: trap_mode = current_mode;
        default:       trap_mode = current_mode;
    endcase
end

assign is_delegated = (trap_mode != M_MODE) &&
                      !m_interrupt_active &&
                      (s_interrupt_active ||
                       (exception_active && medeleg_i[exception_cause_code]));

logic trap_to_s_mode;
assign trap_to_s_mode = trap_o && is_delegated;

// Interrupt cause code for vectored tvec offset
logic [31:0] current_cause;
always_comb begin
    if (meip_i && mie_i[11])
        current_cause = 32'd11;
    else if (mtip_i && mie_i[7])
        current_cause = 32'd7;
    else if (msip_i && mie_i[3])
        current_cause = 32'd3;
    else if (seip_eff_i && mie_i[9] && mideleg_i[9])
        current_cause = 32'd9;
    else if (stip_eff_i && mie_i[5] && mideleg_i[5])
        current_cause = 32'd5;
    else if (ssip_i && mie_i[1] && mideleg_i[1])
        current_cause = 32'd1;
    else
        current_cause = 32'd0;
end

//////////////////////////////////
// Trap EPC and TVAL Resolution //
//////////////////////////////////

// Return address used by mret/sret
assign epc_o = dret_active ? dpc_i  :
               sret_active ? sepc_i :
                             mepc_i;

// Trap vector, resolved to correct mode with vectored mode
assign tvec_o = debug_mode_active && exception_active
                ? ((trap_src == TRAP_SRC_ID && ebreak_active_i)
                   ? DmBase + DmHaltOffset
                   : DmBase + DmExcOffset)
                : debug_entry
                ? DmBase + DmHaltOffset
                : trap_to_s_mode
                ? ((stvec_i[1:0] == 2'b01 && interrupt_active)
                   ? {stvec_i[31:2], 2'b0} + {current_cause[29:0], 2'b0}  // vectored S-mode trap
                   : {stvec_i[31:2], 2'b0})                               // direct S-mode trap
                : ((mtvec_i[1:0] == 2'b01 && interrupt_active)
                   ? {mtvec_i[31:2], 2'b0} + {current_cause[29:0], 2'b0}  // vectored M-mode trap
                   : {mtvec_i[31:2], 2'b0});                              // direct M-mode trap

addr_t trap_epc;
always_comb begin
    unique case (trap_src)
        TRAP_SRC_IF:   trap_epc = pc_i;
        TRAP_SRC_ID:   trap_epc = pc_i;
        TRAP_SRC_EX:   trap_epc = ex_trap_pc_i;
        TRAP_SRC_MEM:  trap_epc = mem_trap_pc_i;
        TRAP_SRC_NONE: trap_epc = pc_i;
        default:       trap_epc = pc_i;
    endcase
end

addr_t trap_tval;
always_comb begin
    unique case (trap_src)
        TRAP_SRC_IF:  trap_tval = (if_trap == IF_TRAP_ACCESS) ? '0 : fault_addr_q_i;
        TRAP_SRC_ID:  trap_tval = illegal_inst_i      ? ir_i.b              :
                                  target_misaligned_i ? misaligned_target_i : '0;
        TRAP_SRC_EX:  trap_tval = ex_trap_va_i;
        TRAP_SRC_MEM:
            if (mem_trap_i == MEM_TRAP_LOAD_ACCESS || mem_trap_i == MEM_TRAP_STORE_ACCESS)
                trap_tval = '0;
            else
                trap_tval = mem_trap_va_i;
        TRAP_SRC_NONE: trap_tval = '0;
        default:       trap_tval = '0;
    endcase
end

//////////////////////////////////////////
// Trap Commit Commands to the CSR File //
//////////////////////////////////////////

// Interrupt causes take priority over exception causes, matching the tvec resolution above.
assign trap_csr_en_o   = trap_o && !debug_mode_active;
assign trap_to_debug_o = debug_entry;
assign trap_to_s_o     = is_delegated;
assign trap_epc_o      = trap_epc;
assign trap_cause_o    = interrupt_active
                       ? {1'b1, current_cause[30:0]} : data_t'(exception_cause_code);
assign trap_tval_o     = trap_tval;
assign trap_mode_o     = trap_mode;
assign dcsr_cause_o    = dbg_req_i       ? 3'd3 : // haltreq
                         ebreak_to_debug ? 3'd1 : // ebreak
                                           3'd4;  // step

///////////////////////
// Hart State Update //
///////////////////////

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) trap_seen <= 1'b0;
    else begin
        if (!trap_raw) trap_seen <= 1'b0;
        if (trap_o)    trap_seen <= 1'b1;
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) if_trap_inhibit <= 1'b0;
    else begin
        if (trap_o) if_trap_inhibit <= 1'b1;
        else if (!stall_i && !(inst_fault_i || inst_err_i || inst_pmp_fault_i))
            if_trap_inhibit <= 1'b0;
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
        in_ebreak_handler <= 1'b0;
    else if (trap_o && trap_src == TRAP_SRC_ID && ebreak_active_i)
        in_ebreak_handler <= 1'b1;
    else if (ret_commit_i && (mret_active || sret_active || dret_active))
        in_ebreak_handler <= 1'b0;
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        current_mode      <= M_MODE;
        debug_mode_active <= 1'b0;
        mret_inhibit      <= 1'b0;
        step              <= StepOff;
    end else begin

        if (mret_inhibit && !stall_i) mret_inhibit <= 1'b0;

        if (step == StepArmed && (id_dispatch || trap_o)) step <= StepFire;

        if (trap_o) begin
            mret_inhibit <= 1'b0;
            // A trap taken while in debug mode redirects only, without any state update
            if (!debug_mode_active) begin
                if (debug_entry) begin
                    debug_mode_active <= 1'b1;
                    current_mode      <= M_MODE;
                    step              <= StepOff;
                end else if (trap_to_s_mode) begin
                    current_mode <= S_MODE;
                end else begin
                    // Non-delegated trap: enter M-mode
                    current_mode <= M_MODE;
                end
            end
        end else if (ret_commit_i && dret_active) begin
            mret_inhibit      <= 1'b1;
            debug_mode_active <= 1'b0;
            current_mode      <= dcsr_i.prv;
            step              <= dcsr_i.step ? StepArmed : StepOff;
        end else if (ret_commit_i && sret_active) begin
            mret_inhibit <= 1'b1;
            current_mode <= mstatus_i.spp ? S_MODE : U_MODE;
        end else if (ret_commit_i && mret_active) begin
            mret_inhibit <= 1'b1;
            current_mode <= mstatus_i.mpp;
        end
    end
end

endmodule

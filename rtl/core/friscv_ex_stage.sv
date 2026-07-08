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
 * This module implements the Execute (EX) stage of the FRISC-V pipeline.
 * It performs ALU operations, calculates branch targets, and handles traps that occur during execution
 * (misaligned redirects). Traps are held until the instruction commits in ID to avoid complications with flushing
 * and redirecting in the middle of EX.
 *
 * The main datapath components in this stage are the ALU and the branch unit. The ALU supports all the operations
 * required by the RISC-V spec, as well as multiplication and division if enabled (ENABLE_MUL and ENABLE_DIV).
 *
 * EX also executes TLB flushes during the first cycle of the SFENCE.VMA instruction. The flush signal is pulsed
 * for one cycle to avoid repeat flushes that cause a livelock.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_ex_stage (
    input  logic           clk_in,
    input  logic           rst_n_in,

    // Stage control signals
    input  logic           stage_stall_in,
    input  logic           stage_flush_in,
  
    // Inputs from ID stage 
    input  addr_t          pc_in,
    input  addr_t          pc_plus_4_in,
    input  data_t          rs1_in,
    input  data_t          rs2_in,
    input  data_t          imm32_in,
    input  data_t          csr_in,
    input  reg_addr_t      rd_sel_in,
    input  reg_addr_t      rs1_sel_in,
    input  reg_addr_t      rs2_sel_in,
    input  mode_e          mode_in,
    input  instr_ex_t      instr_ex_in,

    // Outputs to MEM stage
    output addr_t          pc_out,
    output addr_t          pc_plus_4_out,
    output data_t          alu_data_out,
    output reg_addr_t      rd_sel_out,
    output data_t          store_data_out,
    output mem_instr_sel_e mem_instr_sel_out,
	output mem_width_e     load_store_width_out,
    output wb_data_sel_e   wb_data_sel_out,
    output logic           reserve_out,
    output logic           conditional_out,
    output amo_op_e        amo_op_out,
    output csr_addr_e      csr_sel_out,
    output data_t          csr_readback_out,
    output logic           csr_en_out,
    output logic           instr_valid_out,
    output mode_e          mode_out,

    // Outputs to control logic
    output logic           branch_ok_out,
    output logic           div_active_out,
    output addr_t          branch_target_out,

    // Trap signals
    input  logic           trap_commit_in,
    output ex_trap_e       trap_out,
    output addr_t          trap_pc_out,
    output addr_t          trap_va_out,

    // TLB flush
    output logic           flush_tlb_out,
    output vpn_t           flush_vpn_out,
    output logic           flush_vpn_en_out,
    output asid_t          flush_asid_out,
    output logic           flush_asid_en_out
);

// Input registers
addr_t pc_buff;
addr_t pc_plus_4_buff;
data_t rs1_buff;
data_t rs2_buff;
data_t imm32_buff;
data_t csr_buff;
mode_e mode_buff;

reg_addr_t rd_sel_buff;
reg_addr_t rs1_sel_buff;
reg_addr_t rs2_sel_buff;
instr_ex_t instr_buff;
data_t alu_data_raw;
logic branch_ok_raw;
logic branch_ok_prev;
logic sfence_vma_prev;
logic misaligned_branch_raw;

// ============================================================
// Branch control
// ============================================================

ex_trap_e r_trap;
addr_t    r_trap_pc;
addr_t    r_trap_va;

assign trap_out = r_trap;
assign trap_pc_out = r_trap_pc;
assign trap_va_out = r_trap_va;

data_t branch_target;

friscv_ex_stage_branch_unit branch_unit (
    .branch_jal_sel_in ( instr_buff.branch_jal_sel ),
    .branch_cond_in    ( instr_buff.branch_cond    ),
    .src1_in           ( rs1_buff                  ),
    .src2_in           ( rs2_buff                  ),
    .target            ( branch_target             ),
    .branch_ok_out     ( branch_ok_raw             ),
    .misaligned_out    ( misaligned_branch_raw     )
);

assign branch_target_out = branch_target;

// ============================================================
// Non-restoring divider
// ============================================================

logic [31:0] div_q, div_r;

data_t alu_input_a;
data_t alu_input_b;

generate if (ENABLE_DIV) begin : gen_div
    logic div_active, div_done;
    logic div_started;
    logic div_done_latched;

    logic div_start_pulse;
    assign div_start_pulse = instr_buff.div_en && !div_started && !div_done_latched;

    logic div_flush;
    assign div_flush = stage_flush_in || trap_commit_in;

    data_t div_a_reg, div_b_reg;
    logic  div_signed_reg;
    logic  div_start_r;

    always_ff @(posedge clk_in) begin
        if (!rst_n_in || div_flush || !instr_buff.div_en || (div_done_latched && !stage_stall_in)) begin
            div_started      <= 1'b0;
            div_done_latched <= 1'b0;
            div_start_r      <= 1'b0;
            div_a_reg        <= '0;
            div_b_reg        <= '0;
            div_signed_reg   <= 1'b0;
        end else begin
            div_start_r <= div_start_pulse;
            if (div_start_pulse) begin
                div_started  <= 1'b1;
                div_a_reg    <= alu_input_a;
                div_b_reg    <= alu_input_b;
                div_signed_reg <= instr_buff.div_signed;
            end
            if (div_done)
                div_done_latched <= 1'b1;
        end
    end

    friscv_divider i_divider (
        .clk_in               ( clk_in         ),
        .rst_n_in             ( rst_n_in       ),
        .flush_in             ( div_flush      ),
        .division_detected_in ( div_start_r    ),
        .signed_division_in   ( div_signed_reg ),
        .divisor              ( div_b_reg      ),
        .dividend             ( div_a_reg      ),
        .quotient             ( div_q          ),
        .remainder            ( div_r          ),
        .active_out           ( div_active     ),
        .done_out             ( div_done       )
    );

    assign div_active_out = instr_buff.div_en && !div_done_latched;
end else begin : gen_no_div
    assign div_q = '0;
    assign div_r = '0;
    assign div_active_out = 1'b0;
end endgenerate

// ============================================================
// Input capture
// ============================================================

always_ff @(posedge clk_in) begin
    if (!rst_n_in) begin

        pc_plus_4_buff <= '0;
        pc_buff      <= '0;
        rs1_buff     <= '0;
        rs2_buff     <= '0;
        imm32_buff   <= '0;
        csr_buff     <= '0;
        rd_sel_buff  <= 5'b0;
        rs1_sel_buff <= 5'b0;
        rs2_sel_buff <= 5'b0;
        mode_buff    <= M_MODE;
        instr_buff   <= NOP_CTRL;
        branch_ok_prev <= 1'b0;
        sfence_vma_prev <= 1'b0;
        r_trap <= EX_TRAP_NONE;
        r_trap_pc <= '0;
        r_trap_va <= '0;

    end else begin

        if (trap_commit_in) begin
            // The trap has been consumed by ID.
            r_trap <= EX_TRAP_NONE;
            r_trap_pc <= '0;
            r_trap_va <= '0;
            instr_buff <= NOP_CTRL;
            rd_sel_buff <= 5'b0;

        end else if (r_trap != EX_TRAP_NONE) begin
            // Hold the captured trap until ID commits it.

        end else if (!stage_stall_in) begin

            if (instr_buff.instr_valid &&
                branch_ok_raw &&
                misaligned_branch_raw
            ) begin
                // Stop the pipeline on a taken misaligned branch
                instr_buff <= NOP_CTRL;
                rd_sel_buff <= 5'b0;
                branch_ok_prev <= 1'b0;
                sfence_vma_prev <= 1'b0;

                r_trap <= EX_TRAP_MISALIGNED;
                r_trap_pc <= pc_buff;
                r_trap_va <= branch_target;

            end else begin
                if (stage_flush_in || branch_ok_out) begin
                    pc_buff     <= 32'h0;
                    rd_sel_buff <= 5'b0;
                    mode_buff   <= M_MODE;
                    instr_buff  <= NOP_CTRL;
                end else begin
                    pc_plus_4_buff <= pc_plus_4_in;
                    pc_buff        <= pc_in;
                    rs1_buff       <= rs1_in;
                    rs2_buff       <= rs2_in;
                    imm32_buff     <= imm32_in;
                    csr_buff       <= csr_in;
                    rd_sel_buff    <= rd_sel_in;
                    rs1_sel_buff   <= rs1_sel_in;
                    rs2_sel_buff   <= rs2_sel_in;
                    mode_buff      <= mode_in;
                    instr_buff     <= instr_ex_in;
                end

                // Pulse branch redirect and sfence.vma side effect only once per instruction
                branch_ok_prev <= branch_ok_raw;
                sfence_vma_prev <= instr_buff.sfence_vma;
            end

        end else begin
            branch_ok_prev <= branch_ok_raw;
            sfence_vma_prev <= instr_buff.sfence_vma;
        end

    end
end

// ============================================================
// Assign outputs
// ============================================================

assign pc_out               = pc_buff;
assign pc_plus_4_out        = pc_plus_4_buff;
assign mem_instr_sel_out    = instr_buff.mem_instr_sel;
assign load_store_width_out = instr_buff.load_store_width;
assign wb_data_sel_out      = instr_buff.wb_data_sel;
assign reserve_out          = instr_buff.reserve;
assign conditional_out      = instr_buff.conditional;
assign amo_op_out           = instr_buff.amo_op;
assign rd_sel_out           = rd_sel_buff;
assign csr_sel_out          = instr_buff.csr_addr;
assign csr_readback_out     = csr_buff;
assign csr_en_out           = instr_buff.csr_op;
assign instr_valid_out      = instr_buff.instr_valid;
assign mode_out             = mode_buff;
assign branch_ok_out        = branch_ok_raw && !branch_ok_prev && !misaligned_branch_raw;
assign flush_tlb_out        = instr_buff.sfence_vma && !sfence_vma_prev;
assign flush_vpn_out        = vpn_t'(rs1_buff[31:12]);
assign flush_vpn_en_out     = (rs1_sel_buff != 5'b0);
assign flush_asid_out       = asid_t'(rs2_buff[8:0]);
assign flush_asid_en_out    = (rs2_sel_buff != 5'b0);

// ============================================================
// ALU input select
// ============================================================

data_t a_bus;
data_t b_bus;

always_comb begin
    case (instr_buff.a_bus_sel)
        RS1:     a_bus = rs1_buff;
        ZERO_A:  a_bus = 32'b0;
        PC:      a_bus = pc_buff;
        RS1_SEL: a_bus = {27'b0, rs1_sel_buff};
        default: a_bus = 32'b0;
    endcase

    case (instr_buff.b_bus_sel)
        RS2:     b_bus = rs2_buff;
        IMM:     b_bus = imm32_buff;
        CSR:     b_bus = csr_buff;
        default: b_bus = 32'b0;
    endcase
end

// The invert_op_a signal can be used for bit-clearing operations, such as in CSRRC,
// where new_value = old_value & ~rs1.
assign alu_input_a = (instr_buff.invert_op_a) ? ~a_bus : a_bus;
assign alu_input_b = b_bus;

// Dedicated adder for branch/jump targets
// This is a separate adder from the one used for the main ALU to avoid critical path issues.
// As the divider and multiplier are also on the main ALU path, STA will complain about timing
// even though the result of multiplication or division will never be a redirection target.
data_t addr_result;
assign addr_result = alu_input_a + alu_input_b;
// Also clear bit 0 for JALR targets, as required by the spec.
assign branch_target = instr_buff.jalr_target ? {addr_result[31:1], 1'b0} : addr_result;

// ============================================================
// Multiplier
// ============================================================

data_t mul_result_lo, mul_result_hi;

generate if (ENABLE_MUL) begin : gen_mul
    // The goal here is to do only one 33x33 multiplication with pre-signed operands,
    // instead of separate signed/unsigned multiplications with 4 32x32 multipliers.
    // This saves area and improves timing, at the cost of minimal extra logic.
    logic signed [32:0] mul_op_a, mul_op_b;
    logic signed [65:0] mul_result;

    always_comb begin
        // A: sign-extend for MULH, MULHSU, zero-extend for MULHU
        case (instr_buff.alu_op)
            MULHU_OP: mul_op_a = {1'b0, alu_input_a};
            default:  mul_op_a = {alu_input_a[31], alu_input_a};
        endcase

        // B: sign-extend for MULH only, zero-extend for MULHU, MULHSU
        case (instr_buff.alu_op)
            MULH_OP: mul_op_b = {alu_input_b[31], alu_input_b};
            default: mul_op_b = {1'b0, alu_input_b};
        endcase
    end

    // Here is the single multiplier
    assign mul_result = mul_op_a * mul_op_b;
    assign mul_result_lo = mul_result[31:0];
    assign mul_result_hi = mul_result[63:32];
end else begin : gen_no_mul
    assign mul_result_lo = '0;
    assign mul_result_hi = '0;
end endgenerate

// ============================================================
// Execute operation
// ============================================================

always_comb begin
    case (instr_buff.alu_op)
        ADD_OP:    alu_data_raw = alu_input_a + alu_input_b;
        SUB_OP:    alu_data_raw = alu_input_a - alu_input_b;
        AND_OP:    alu_data_raw = alu_input_a & alu_input_b;
        OR_OP:     alu_data_raw = alu_input_a | alu_input_b;
        XOR_OP:    alu_data_raw = alu_input_a ^ alu_input_b;
        SLL_OP:    alu_data_raw = alu_input_a << alu_input_b[4:0];
        SRL_OP:    alu_data_raw = alu_input_a >> alu_input_b[4:0];
        SRA_OP:    alu_data_raw = $signed(alu_input_a) >>> alu_input_b[4:0];
        SLT_OP:    alu_data_raw = {31'b0, $signed(alu_input_a) < $signed(alu_input_b)};
        SLTU_OP:   alu_data_raw = {31'b0, alu_input_a < alu_input_b};
        MUL_OP:    alu_data_raw = mul_result_lo;
        MULH_OP:   alu_data_raw = mul_result_hi;
        MULHU_OP:  alu_data_raw = mul_result_hi;
        MULHSU_OP: alu_data_raw = mul_result_hi;
        DIV_OP:    alu_data_raw = div_q;
        DIVU_OP:   alu_data_raw = div_q;
        REM_OP:    alu_data_raw = div_r;
        REMU_OP:   alu_data_raw = div_r;
        default:   alu_data_raw = 32'h0;
    endcase
end

assign alu_data_out = alu_data_raw;

// ============================================================
// Position store data
// ============================================================

// Based on the store width and the least significant bits of the address,
// here we position the store data correctly for the downstream memory unit.
// ie. for a byte store to 0x1003, the byte to be stored will be in bits [31:24] of store_data_out.

always_comb begin
    case (instr_buff.load_store_width)
        3'b000: begin   // Byte (8b)
            case (alu_data_out[1:0]) 
                2'b00: store_data_out = {24'h0, rs2_buff[7:0]};
                2'b01: store_data_out = {16'h0, rs2_buff[7:0],  8'h0};
                2'b10: store_data_out = { 8'h0, rs2_buff[7:0], 16'h0};
                2'b11: store_data_out = {rs2_buff[7:0], 24'h0};
            endcase
        end
        3'b001: begin   // Half (16b)
            if (alu_data_out[1]) store_data_out = {rs2_buff[15:0], 16'h0};
            else                 store_data_out = {16'h0, rs2_buff[15:0]};
        end
        3'b010:  store_data_out = rs2_buff; // Word (32b)
        default: store_data_out = 32'h0;
    endcase
end

endmodule

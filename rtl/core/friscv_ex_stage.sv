// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

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

module friscv_ex_stage import friscv_pkg::*; #(
    parameter bit EnableIsaM    = 1,
    // Use a single-cycle combinational multiplier instead of the iterative multiplier
    parameter bit EnableFastMul = 0
) (
    input  logic           clk_i,
    input  logic           rst_ni,

    // Stage control signals
    input  logic           stall_i,
    input  logic           flush_i,
  
    // Inputs from ID stage 
    input  addr_t          pc_i,
    input  addr_t          next_pc_i,
    input  data_t          rs1_i,
    input  data_t          rs2_i,
    input  data_t          imm32_i,
    input  data_t          csr_i,
    input  reg_addr_t      rd_sel_i,
    input  reg_addr_t      rs1_sel_i,
    input  reg_addr_t      rs2_sel_i,
    input  mode_e          mode_i,
    input  instr_ex_t      instr_ex_i,

    // Outputs to MEM stage
    output addr_t          pc_o,
    output addr_t          next_pc_o,
    output data_t          alu_data_o,
    output reg_addr_t      rd_sel_o,
    output data_t          store_data_o,
    output mem_instr_sel_e mem_instr_sel_o,
    output mem_width_e     load_store_width_o,
    output wb_data_sel_e   wb_data_sel_o,
    output logic           reserve_o,
    output logic           conditional_o,
    output amo_op_e        amo_op_o,
    output csr_addr_e      csr_sel_o,
    output data_t          csr_readback_o,
    output logic           csr_en_o,
    output logic           instr_valid_o,
    output mode_e          mode_o,

    // Outputs to control logic
    output logic           branch_ok_o,
    output logic           muldiv_active_o,
    output addr_t          branch_target_o,
    output logic           csr_is_ser_o,

    // Trap signals
    input  logic           trap_commit_i,
    output ex_trap_e       trap_o,
    output addr_t          trap_pc_o,
    output addr_t          trap_va_o,

    // TLB flush
    output logic           flush_tlb_o,
    output vpn_t           flush_vpn_o,
    output logic           flush_vpn_en_o,
    output asid_t          flush_asid_o,
    output logic           flush_asid_en_o
);

// Input registers
addr_t pc_q;
addr_t next_pc_q;
data_t rs1_q;
data_t rs2_q;
data_t imm32_q;
data_t csr_q;
mode_e mode_q;

reg_addr_t rd_sel_q;
reg_addr_t rs1_sel_q;
reg_addr_t rs2_sel_q;
instr_ex_t instr_q;
data_t alu_data_raw;
logic branch_ok_raw;
logic branch_ok_prev;
logic sfence_vma_prev;
logic misaligned_branch_raw;

// ============================================================
// Branch control
// ============================================================

ex_trap_e trap;
addr_t    trap_pc;
addr_t    trap_va;

assign trap_o = trap;
assign trap_pc_o = trap_pc;
assign trap_va_o = trap_va;

data_t branch_target;

friscv_branch_unit i_branch_unit (
    .branch_jal_sel_i ( instr_q.branch_jal_sel ),
    .branch_cond_i    ( instr_q.branch_cond    ),
    .src1_i           ( rs1_q                  ),
    .src2_i           ( rs2_q                  ),
    .target_i         ( branch_target          ),
    .branch_ok_o      ( branch_ok_raw          ),
    .misaligned_o     ( misaligned_branch_raw  )
);

assign branch_target_o = branch_target;

// ============================================================
// Multiply/divide units
// ============================================================

data_t alu_input_a;
data_t alu_input_b;

logic [63:0] muldiv_res;
logic        mul_en;
logic        div_en;
logic        muldiv_en;
logic        a_signed;
logic        b_signed;

assign mul_en = EnableIsaM && ((instr_q.alu_op == MUL_OP   ) ||
                               (instr_q.alu_op == MULH_OP  ) ||
                               (instr_q.alu_op == MULHU_OP ) ||
                               (instr_q.alu_op == MULHSU_OP));
assign div_en = EnableIsaM && ((instr_q.alu_op == DIV_OP ) ||
                               (instr_q.alu_op == DIVU_OP) ||
                               (instr_q.alu_op == REM_OP ) ||
                               (instr_q.alu_op == REMU_OP));
assign muldiv_en = (mul_en && !EnableFastMul) || div_en;

assign a_signed = (instr_q.alu_op == MULH_OP)  ||
                  (instr_q.alu_op == MULHSU_OP) ||
                  (instr_q.alu_op == DIV_OP)    ||
                  (instr_q.alu_op == REM_OP);
assign b_signed = (instr_q.alu_op == MULH_OP) ||
                  (instr_q.alu_op == DIV_OP)  ||
                  (instr_q.alu_op == REM_OP);

if (EnableIsaM && !EnableFastMul) begin : gen_muldiv
    logic done;
    logic started;
    logic done_hold;
    logic start;
    logic flush;

    assign start = muldiv_en && !started && !done_hold;
    assign flush = flush_i || trap_commit_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            started   <= 1'b0;
            done_hold <= 1'b0;
        end else if (flush || !muldiv_en || (done_hold && !stall_i)) begin
            started   <= 1'b0;
            done_hold <= 1'b0;
        end else begin
            if (start) started <= 1'b1;
            if (done)  done_hold <= 1'b1;
        end
    end

    friscv_muldiv i_muldiv (
        .clk_i,
        .rst_ni,
        .flush_i    ( flush       ),
        .start_i    ( start       ),
        .mul_i      ( mul_en      ),
        .a_signed_i ( a_signed    ),
        .b_signed_i ( b_signed    ),
        .a_i        ( alu_input_a ),
        .b_i        ( alu_input_b ),
        .result_o   ( muldiv_res  ),
        .done_o     ( done        )
    );

    assign muldiv_active_o = muldiv_en && !done_hold;
end else begin : gen_no_muldiv
    assign muldiv_res = '0;
    assign muldiv_active_o = 1'b0;
end

data_t mul_res_lo, mul_res_hi;

if (EnableIsaM && EnableFastMul) begin : gen_fast_mul
    logic signed [32:0] op_a, op_b;
    logic signed [65:0] product;

    always_comb begin
        if (instr_q.alu_op == MULHU_OP) op_a = {1'b0, alu_input_a};
        else                            op_a = {alu_input_a[31], alu_input_a};

        if (instr_q.alu_op == MULH_OP)  op_b = {alu_input_b[31], alu_input_b};
        else                            op_b = {1'b0, alu_input_b};
    end

    assign product = op_a * op_b;
    assign mul_res_lo = product[31:0];
    assign mul_res_hi = product[63:32];
end else begin : gen_iter_mul
    assign mul_res_lo = muldiv_res[31:0];
    assign mul_res_hi = muldiv_res[63:32];
end

// ============================================================
// Input capture
// ============================================================

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin

        next_pc_q <= '0;
        pc_q      <= '0;
        rs1_q     <= '0;
        rs2_q     <= '0;
        imm32_q   <= '0;
        csr_q     <= '0;
        rd_sel_q  <= 5'b0;
        rs1_sel_q <= 5'b0;
        rs2_sel_q <= 5'b0;
        mode_q    <= M_MODE;
        instr_q   <= NOP_CTRL;
        branch_ok_prev <= 1'b0;
        sfence_vma_prev <= 1'b0;
        trap    <= EX_TRAP_NONE;
        trap_pc <= '0;
        trap_va <= '0;

    end else begin

        if (trap_commit_i) begin
            // The trap has been consumed by ID.
            trap     <= EX_TRAP_NONE;
            trap_pc  <= '0;
            trap_va  <= '0;
            instr_q  <= NOP_CTRL;
            rd_sel_q <= 5'b0;

        end else if (trap != EX_TRAP_NONE) begin
            // Hold the captured trap until ID commits it.

        end else if (!stall_i) begin

            if (instr_q.instr_valid && branch_ok_raw && misaligned_branch_raw ) begin
                // Stop the pipeline on a taken misaligned branch
                instr_q  <= NOP_CTRL;
                rd_sel_q <= 5'b0;
                branch_ok_prev  <= 1'b0;
                sfence_vma_prev <= 1'b0;

                trap    <= EX_TRAP_MISALIGNED;
                trap_pc <= pc_q;
                trap_va <= branch_target;

            end else begin
                if (flush_i || branch_ok_o) begin
                    pc_q     <= 32'h0;
                    rd_sel_q <= 5'b0;
                    mode_q   <= M_MODE;
                    instr_q  <= NOP_CTRL;
                end else begin
                    next_pc_q <= next_pc_i;
                    pc_q      <= pc_i;
                    rs1_q     <= rs1_i;
                    rs2_q     <= rs2_i;
                    imm32_q   <= imm32_i;
                    csr_q     <= csr_i;
                    rd_sel_q  <= rd_sel_i;
                    rs1_sel_q <= rs1_sel_i;
                    rs2_sel_q <= rs2_sel_i;
                    mode_q    <= mode_i;
                    instr_q   <= instr_ex_i;
                end

                // Pulse branch redirect and sfence.vma side effect only once per instruction
                branch_ok_prev  <= branch_ok_raw;
                sfence_vma_prev <= instr_q.sfence_vma;
            end

        end else begin
            branch_ok_prev  <= branch_ok_raw;
            sfence_vma_prev <= instr_q.sfence_vma;
        end

    end
end

// ============================================================
// Assign outputs
// ============================================================

assign pc_o               = pc_q;
assign next_pc_o          = next_pc_q;
assign mem_instr_sel_o    = instr_q.mem_instr_sel;
assign load_store_width_o = instr_q.load_store_width;
assign wb_data_sel_o      = instr_q.wb_data_sel;
assign reserve_o          = instr_q.reserve;
assign conditional_o      = instr_q.conditional;
assign amo_op_o           = instr_q.amo_op;
assign rd_sel_o           = muldiv_active_o ? '0 : rd_sel_q;
assign csr_sel_o          = instr_q.csr_addr;
assign csr_readback_o     = csr_q;
assign csr_en_o           = instr_q.csr_op;
assign instr_valid_o      = instr_q.instr_valid && !muldiv_active_o;
assign mode_o             = mode_q;
assign branch_ok_o        = branch_ok_raw && !branch_ok_prev && !misaligned_branch_raw;
assign flush_tlb_o        = instr_q.sfence_vma && !sfence_vma_prev;
assign flush_vpn_o        = vpn_t'(rs1_q[31:12]);
assign flush_vpn_en_o     = (rs1_sel_q != 5'b0);
assign flush_asid_o       = asid_t'(rs2_q[8:0]);
assign flush_asid_en_o    = (rs2_sel_q != 5'b0);
assign csr_is_ser_o       = instr_q.csr_is_serializing;

// ============================================================
// ALU input select
// ============================================================

data_t a_bus;
data_t b_bus;

always_comb begin
    unique case (instr_q.a_bus_sel)
        RS1:     a_bus = rs1_q;
        ZERO_A:  a_bus = 32'b0;
        PC:      a_bus = pc_q;
        RS1_SEL: a_bus = {27'b0, rs1_sel_q};
        default: a_bus = 32'b0;
    endcase

    unique case (instr_q.b_bus_sel)
        RS2:     b_bus = rs2_q;
        IMM:     b_bus = imm32_q;
        CSR:     b_bus = csr_q;
        default: b_bus = 32'b0;
    endcase
end

// The invert_op_a signal can be used for bit-clearing operations, such as in CSRRC,
// where new_value = old_value & ~rs1.
assign alu_input_a = (instr_q.invert_op_a) ? ~a_bus : a_bus;
assign alu_input_b = b_bus;

// Dedicated adder for branch/jump targets
// This is a separate adder from the one used for the main ALU to avoid critical path issues.
// As the divider and multiplier are also on the main ALU path, STA will complain about timing
// even though the result of multiplication or division will never be a redirection target.
data_t addr_result;
assign addr_result = alu_input_a + alu_input_b;
// Also clear bit 0 for JALR targets, as required by the spec.
assign branch_target = instr_q.jalr_target ? {addr_result[31:1], 1'b0} : addr_result;

// ============================================================
// Execute operation
// ============================================================

always_comb begin
    unique case (instr_q.alu_op)
        ADD_OP:    alu_data_raw = alu_input_a + alu_input_b;
        SUB_OP:    alu_data_raw = alu_input_a - alu_input_b;
        AND_OP:    alu_data_raw = alu_input_a & alu_input_b;
        OR_OP:     alu_data_raw = alu_input_a | alu_input_b;
        XOR_OP:    alu_data_raw = alu_input_a ^ alu_input_b;
        SLL_OP:    alu_data_raw = alu_input_a << alu_input_b[4:0];
        SRL_OP:    alu_data_raw = alu_input_a >> alu_input_b[4:0];
        SRA_OP:    alu_data_raw = data_t'($signed(alu_input_a) >>> alu_input_b[4:0]);
        SLT_OP:    alu_data_raw = {31'b0, $signed(alu_input_a) < $signed(alu_input_b)};
        SLTU_OP:   alu_data_raw = {31'b0, alu_input_a < alu_input_b};
        MUL_OP:    alu_data_raw = mul_res_lo;
        MULH_OP:   alu_data_raw = mul_res_hi;
        MULHU_OP:  alu_data_raw = mul_res_hi;
        MULHSU_OP: alu_data_raw = mul_res_hi;
        DIV_OP:    alu_data_raw = muldiv_res[31:0];
        DIVU_OP:   alu_data_raw = muldiv_res[31:0];
        REM_OP:    alu_data_raw = muldiv_res[63:32];
        REMU_OP:   alu_data_raw = muldiv_res[63:32];
        default:   alu_data_raw = 32'h0;
    endcase
end

assign alu_data_o = alu_data_raw;

// ============================================================
// Position store data
// ============================================================

// Based on the store width and the least significant bits of the address,
// here we position the store data correctly for the downstream memory unit.
// ie. for a byte store to 0x1003, the byte to be stored will be in bits [31:24] of store_data_o.

always_comb begin
    unique case (instr_q.load_store_width)
        WIDTH_U8,
        WIDTH_I8: unique case (alu_data_o[1:0])  // Byte (8b)
            2'b00:   store_data_o = {24'h0, rs2_q[7:0]};
            2'b01:   store_data_o = {16'h0, rs2_q[7:0],  8'h0};
            2'b10:   store_data_o = { 8'h0, rs2_q[7:0], 16'h0};
            2'b11:   store_data_o = {rs2_q[7:0], 24'h0};
            default: store_data_o = 32'h0;
        endcase
        WIDTH_U16,
        WIDTH_I16: store_data_o = (alu_data_o[1]) ? {rs2_q[15:0], 16'h0} : {16'h0, rs2_q[15:0]};  // Halfword (16b)
        WIDTH_I32: store_data_o = rs2_q;  // Word (32b)
        default:   store_data_o = 32'h0;
    endcase
end

endmodule

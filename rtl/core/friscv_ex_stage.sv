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
    output logic           muldiv_active_out,
    output addr_t          branch_target_out,
    output logic           csr_is_serializing_out,

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

friscv_branch_unit i_branch_unit (
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

assign mul_en = EnableIsaM && ((instr_buff.alu_op == MUL_OP   ) ||
                               (instr_buff.alu_op == MULH_OP  ) ||
                               (instr_buff.alu_op == MULHU_OP ) ||
                               (instr_buff.alu_op == MULHSU_OP));
assign div_en = EnableIsaM && ((instr_buff.alu_op == DIV_OP ) ||
                               (instr_buff.alu_op == DIVU_OP) ||
                               (instr_buff.alu_op == REM_OP ) ||
                               (instr_buff.alu_op == REMU_OP));
assign muldiv_en = (mul_en && !EnableFastMul) || div_en;

assign a_signed = (instr_buff.alu_op == MULH_OP)  ||
                  (instr_buff.alu_op == MULHSU_OP) ||
                  (instr_buff.alu_op == DIV_OP)    ||
                  (instr_buff.alu_op == REM_OP);
assign b_signed = (instr_buff.alu_op == MULH_OP) ||
                  (instr_buff.alu_op == DIV_OP)  ||
                  (instr_buff.alu_op == REM_OP);

generate if (EnableIsaM && !EnableFastMul) begin : gen_muldiv
    logic done;
    logic started;
    logic done_hold;
    logic start;
    logic flush;

    assign start = muldiv_en && !started && !done_hold;
    assign flush = stage_flush_in || trap_commit_in;

    always_ff @(posedge clk_in or negedge rst_n_in) begin
        if (!rst_n_in) begin
            started   <= 1'b0;
            done_hold <= 1'b0;
        end else if (flush || !muldiv_en || (done_hold && !stage_stall_in)) begin
            started   <= 1'b0;
            done_hold <= 1'b0;
        end else begin
            if (start)
                started <= 1'b1;
            if (done)
                done_hold <= 1'b1;
        end
    end

    friscv_muldiv i_muldiv (
        .i_clk      ( clk_in      ),
        .i_rstn     ( rst_n_in    ),
        .i_flush    ( flush       ),
        .i_start    ( start       ),
        .i_mul      ( mul_en      ),
        .i_a_signed ( a_signed    ),
        .i_b_signed ( b_signed    ),
        .i_a        ( alu_input_a ),
        .i_b        ( alu_input_b ),
        .o_result   ( muldiv_res  ),
        .o_done     ( done        )
    );

    assign muldiv_active_out = muldiv_en && !done_hold;
end else begin : gen_no_muldiv
    assign muldiv_res = '0;
    assign muldiv_active_out = 1'b0;
end endgenerate

data_t mul_res_lo, mul_res_hi;

generate if (EnableIsaM && EnableFastMul) begin : gen_fast_mul
    logic signed [32:0] op_a, op_b;
    logic signed [65:0] product;

    always_comb begin
        case (instr_buff.alu_op)
            MULHU_OP: op_a = {1'b0, alu_input_a};
            default:  op_a = {alu_input_a[31], alu_input_a};
        endcase

        case (instr_buff.alu_op)
            MULH_OP: op_b = {alu_input_b[31], alu_input_b};
            default: op_b = {1'b0, alu_input_b};
        endcase
    end

    assign product = op_a * op_b;
    assign mul_res_lo = product[31:0];
    assign mul_res_hi = product[63:32];
end else begin : gen_iter_mul
    assign mul_res_lo = muldiv_res[31:0];
    assign mul_res_hi = muldiv_res[63:32];
end endgenerate

// ============================================================
// Input capture
// ============================================================

always_ff @(posedge clk_in or negedge rst_n_in) begin
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

            if (instr_buff.instr_valid && branch_ok_raw && misaligned_branch_raw ) begin
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
assign rd_sel_out           = muldiv_active_out ? '0 : rd_sel_buff;
assign csr_sel_out          = instr_buff.csr_addr;
assign csr_readback_out     = csr_buff;
assign csr_en_out           = instr_buff.csr_op;
assign instr_valid_out      = instr_buff.instr_valid && !muldiv_active_out;
assign mode_out             = mode_buff;
assign branch_ok_out        = branch_ok_raw && !branch_ok_prev && !misaligned_branch_raw;
assign flush_tlb_out        = instr_buff.sfence_vma && !sfence_vma_prev;
assign flush_vpn_out        = vpn_t'(rs1_buff[31:12]);
assign flush_vpn_en_out     = (rs1_sel_buff != 5'b0);
assign flush_asid_out       = asid_t'(rs2_buff[8:0]);
assign flush_asid_en_out    = (rs2_sel_buff != 5'b0);
assign csr_is_serializing_out = instr_buff.csr_is_serializing;

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

assign alu_data_out = alu_data_raw;

// ============================================================
// Position store data
// ============================================================

// Based on the store width and the least significant bits of the address,
// here we position the store data correctly for the downstream memory unit.
// ie. for a byte store to 0x1003, the byte to be stored will be in bits [31:24] of store_data_out.

always_comb begin
    case (instr_buff.load_store_width)
        WIDTH_U8,
        WIDTH_I8: case (alu_data_out[1:0])      // Byte (8b)
            2'b00:   store_data_out = {24'h0, rs2_buff[7:0]};
            2'b01:   store_data_out = {16'h0, rs2_buff[7:0],  8'h0};
            2'b10:   store_data_out = { 8'h0, rs2_buff[7:0], 16'h0};
            2'b11:   store_data_out = {rs2_buff[7:0], 24'h0};
            default: store_data_out = 32'h0;
        endcase
        WIDTH_U16,
        WIDTH_I16:                              // Half (16b)
            if (alu_data_out[1]) store_data_out = {rs2_buff[15:0], 16'h0};
            else                 store_data_out = {16'h0, rs2_buff[15:0]};
        WIDTH_I32:  store_data_out = rs2_buff;  // Word (32b)
        default: store_data_out = 32'h0;
    endcase
end

endmodule

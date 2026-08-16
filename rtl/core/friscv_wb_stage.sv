// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the writeback stage of the FRISC-V pipeline.
 * It takes inputs from the MEM stage, including the results of ALU operations,
 * memory loads, and CSR reads, and produces the data to be written back to the
 * register file, as well as control signals for writing to CSRs and updating instret.
 */

module friscv_wb_stage import friscv_pkg::*; (
    input  logic         clk_i,
    input  logic         rst_ni,

    // Stage control
    input  logic         stall_i,
    output logic         csr_is_ser_o,

    // Inputs from MEM stage
    input  addr_t        next_pc_i,
    input  data_t        alu_data_i,
    input  data_t        load_data_i,
    input  data_t        sc_res_i,
    input  wb_data_sel_e wb_data_sel_i,
    input  reg_addr_t    rd_sel_i,
    input  csr_addr_e    csr_sel_i,
    input  data_t        csr_data_i,
    input  data_t        csr_readback_i,
    input  logic         csr_en_i,
    input  logic         csr_is_ser_i,
    input  logic         instr_valid_i,

    // Outputs to ID stage (regfile write, CSR write, instret)
    output data_t        rd_data_o,
    output reg_addr_t    rd_sel_o,
    output csr_addr_e    csr_sel_o,
    output data_t        csr_data_o,
    output logic         csr_en_o,
    output logic         instr_valid_o,
    output logic         inst_ret_o
);

addr_t        next_pc_q;
data_t        alu_data_q;
data_t        load_data_q;
data_t        sc_res_q;
wb_data_sel_e wb_data_sel_q;
reg_addr_t    rd_sel_q;
csr_addr_e    csr_sel_q;
data_t        csr_data_q;
data_t        csr_readback_q;
logic         csr_en_q;
logic         csr_is_ser_q;
logic         instr_valid_q;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        next_pc_q      <= '0;
        alu_data_q     <= '0;
        load_data_q    <= '0;
        sc_res_q       <= '0;
        wb_data_sel_q  <= WB_DATA_SEL_ALU;
        rd_sel_q       <= 5'b0;
        csr_sel_q      <= CSR_ZERO;
        csr_data_q     <= '0;
        csr_readback_q <= '0;
        csr_en_q       <= 1'b0;
        csr_is_ser_q   <= 1'b0;
        instr_valid_q  <= 1'b0;
    end else if (!stall_i) begin
        next_pc_q      <= next_pc_i;
        alu_data_q     <= alu_data_i;
        load_data_q    <= load_data_i;
        sc_res_q       <= sc_res_i;
        wb_data_sel_q  <= wb_data_sel_i;
        rd_sel_q       <= rd_sel_i;
        csr_sel_q      <= csr_sel_i;
        csr_data_q     <= csr_data_i;
        csr_readback_q <= csr_readback_i;
        csr_en_q       <= csr_en_i;
        csr_is_ser_q   <= csr_is_ser_i;
        instr_valid_q  <= instr_valid_i;
    end
end

assign rd_sel_o   = rd_sel_q;
assign csr_sel_o  = csr_sel_q;
assign csr_data_o = csr_data_q;
assign csr_en_o   = csr_en_q;
assign csr_is_ser_o = csr_is_ser_q;
assign instr_valid_o = instr_valid_q;
assign inst_ret_o = instr_valid_q && !stall_i;

////////////////
// Result Mux //
////////////////

always_comb begin
    unique case (wb_data_sel_q)
        WB_DATA_SEL_PC_PLUS_4: rd_data_o = next_pc_q;
        WB_DATA_SEL_ALU:       rd_data_o = alu_data_q;
        WB_DATA_SEL_MEM:       rd_data_o = load_data_q;
        WB_DATA_SEL_SC_RES:    rd_data_o = sc_res_q;
        WB_DATA_SEL_CSR:       rd_data_o = csr_readback_q;
        default:               rd_data_o = 32'b0;
    endcase
end

endmodule

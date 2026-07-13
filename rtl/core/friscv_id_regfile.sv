// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the general-purpose register file for the RISC-V core.
 * Provides three asynchronous read ports and one synchronous write port.
 * Resets to 0.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_id_regfile (
    input  logic      clk_in,
    input  logic      rst_n_in,

    input  reg_addr_t rs1_sel_in,
    input  reg_addr_t rs2_sel_in,
    input  reg_addr_t jump_base_sel_in,
    input  reg_addr_t rd_sel_in,
    input  data_t     rd_data_in,

    output data_t     rs1_data_out,
    output data_t     rs2_data_out,
    output addr_t     jump_base_out
);

data_t regfile [REGISTER_NUM];

assign rs1_data_out  = regfile[rs1_sel_in];
assign rs2_data_out  = regfile[rs2_sel_in];
assign jump_base_out = regfile[jump_base_sel_in];

always @(posedge clk_in) begin
    if (!rst_n_in) for (int unsigned i = 0; i < REGISTER_NUM; i++) regfile[i] <= '0;
    else if (rd_sel_in != 0) regfile[rd_sel_in] <= rd_data_in;
end

endmodule

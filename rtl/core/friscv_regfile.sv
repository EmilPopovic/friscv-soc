// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the general-purpose register file for the RISC-V core.
 * Provides two asynchronous read ports and one synchronous write port.
 */

module friscv_regfile import friscv_pkg::*; #(
    parameter int unsigned RegisterNum = 32
) (
    input  logic      clk_i,
    input  reg_addr_t rs1_sel_i,
    input  reg_addr_t rs2_sel_i,
    input  reg_addr_t rd_sel_i,
    input  data_t     rd_i,
    input  logic      wen_i,
    output data_t     rs1_o,
    output data_t     rs2_o
);

if (RegisterNum < 2) begin : gen_invalid_regfile
    $fatal(1, "Invalid register file size: %0d. Must be at least 2.", RegisterNum);
end

data_t regfile [1:RegisterNum-1]; // Register file, x0 is hardwired to 0

assign rs1_o = (rs1_sel_i == '0) ? '0 : regfile[rs1_sel_i];
assign rs2_o = (rs2_sel_i == '0) ? '0 : regfile[rs2_sel_i];

// Not resetting the register file, not required by spec and improves reset tree
always_ff @(posedge clk_i) begin
    // Never write to x0
    if (rd_sel_i != '0 && wen_i) regfile[rd_sel_i] <= rd_i;
end

endmodule

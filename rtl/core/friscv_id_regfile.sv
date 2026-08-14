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

module friscv_id_regfile import friscv_pkg::*, friscv_mem_pkg::*; #(
    parameter int unsigned RegisterNum = 32
) (
    input  logic      clk_in,
    input  reg_addr_t rs1_sel_in,
    input  reg_addr_t rs2_sel_in,
    input  reg_addr_t rd_sel_in,
    input  data_t     rd_data_in,
    input  logic      wr_en_in,
    output data_t     rs1_data_out,
    output data_t     rs2_data_out
);

if (RegisterNum < 2) begin : gen_invalid_regfile
    $fatal(1, "Invalid register file size: %0d. Must be at least 2.", RegisterNum);
end

data_t r_regfile [RegisterNum-1:1]; // Register file, x0 is hardwired to 0

assign rs1_data_out = rs1_sel_in == 0 ? '0 : r_regfile[rs1_sel_in];
assign rs2_data_out = rs2_sel_in == 0 ? '0 : r_regfile[rs2_sel_in];

always_ff @(posedge clk_in) begin
    // Never write to x0
    if (rd_sel_in != 0 && wr_en_in) r_regfile[rd_sel_in] <= rd_data_in;
end

endmodule

// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_zsbl_rom #(
    parameter int unsigned SIZE_BYTES = 64,
    parameter int unsigned BASE_ADDR  = 32'h20000
) (
    input  logic  i_clk,
    input  addr_t i_addr,
    output inst_t o_data
);

inst_t mem [SIZE_BYTES/4];
localparam int unsigned ZSBL_PROG_WORDS = 7;

logic [31:0] w_word_offset;
logic        w_valid;
inst_t       r_data;

assign w_word_offset = (i_addr - BASE_ADDR) >> 2;
assign w_valid = (i_addr >= BASE_ADDR && w_word_offset < (SIZE_BYTES/4));

always_ff @(posedge i_clk) begin
    if (w_valid) begin
        r_data <= mem[w_word_offset];
    end else begin
        r_data <= NOP;
    end
end

assign o_data = r_data;

always_comb begin
    mem[0] = 32'h4000_02b7;  // 
    mem[1] = 32'h0010_0313;  // 
    mem[2] = 32'h0062_a023;  // 
    mem[3] = 32'h0002_a383;  // 
    mem[4] = 32'hfe63_8ee3;  // 
    mem[5] = 32'h0000_100f;  // 
    mem[6] = 32'h0003_8067;  // 

    for (int unsigned i = ZSBL_PROG_WORDS; i < (SIZE_BYTES/4); i++) begin
        mem[i] = 32'h0000_0000;
    end
end

endmodule

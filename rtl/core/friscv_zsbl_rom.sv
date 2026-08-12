// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

module friscv_zsbl_rom import friscv_pkg::*, friscv_mem_pkg::*; #(
    parameter int unsigned SIZE_BYTES = 64,
    parameter int unsigned BASE_ADDR  = 32'h0020_0000
) (
    input  logic  i_clk,
    input  logic  i_rstn,
    input  addr_t i_addr,
    output inst_t o_data
);

// Round up size to next power of 2
localparam int unsigned REAL_SIZE = 1 << $clog2(SIZE_BYTES);
localparam int unsigned WORDS     = REAL_SIZE / 4;
localparam int unsigned OFFSET_W  = (WORDS > 1) ? $clog2(WORDS) : 1;

import friscv_zsbl_rom_pkg::*;

inst_t mem [WORDS];

if (ZSBL_PROG_WORDS > WORDS) begin : gen_zsbl_too_big
    $fatal(1, "ZSBL needs %0d bytes, REAL_SIZE is %0d", ZSBL_PROG_WORDS*4, REAL_SIZE);
end

logic [OFFSET_W-1:0] w_word_offset;

inst_t r_data;
assign o_data = r_data;

assign w_word_offset = OFFSET_W'((i_addr - BASE_ADDR) >> 2);

always_ff @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn) r_data <= NOP;
    else         r_data <= mem[w_word_offset];
end

for (genvar i = 0; i < WORDS; i++) begin : gen_zsbl_mem
    if (i < ZSBL_PROG_WORDS) begin : gen_prog
        assign mem[i] = ZSBL_PROG[i];
    end else begin : gen_pad
        assign mem[i] = 32'h0000_0000;
    end
end

endmodule

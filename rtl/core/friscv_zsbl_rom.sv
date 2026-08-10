// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

import friscv_pkg::*;
import friscv_zsbl_rom_pkg::*;

module friscv_zsbl_rom import friscv_mem_pkg::*; #(
    parameter int unsigned SIZE_BYTES = 64,
    parameter int unsigned BASE_ADDR  = 32'h0020_0000
) (
    input  logic  i_clk,
    input  addr_t i_addr,
    output inst_t o_data
);

inst_t mem [SIZE_BYTES/4];

if (ZSBL_PROG_WORDS > SIZE_BYTES/4) begin : gen_zsbl_too_big
    $error("ZSBL needs %0d bytes, SIZE_BYTES is %0d", ZSBL_PROG_WORDS*4, SIZE_BYTES);
end

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
    for (int unsigned i = 0; i < (SIZE_BYTES/4); i++) begin
        mem[i] = (i < ZSBL_PROG_WORDS) ? ZSBL_PROG[i] : 32'h0000_0000;
    end
end

endmodule

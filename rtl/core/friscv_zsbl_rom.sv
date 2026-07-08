// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
//
// Version info is listed in friscv_pkg.sv

// AUTO-GENERATED FROM: zsbl.S

/*
 * This module implements the boot ROM for the Zero Stage Boot Loader (ZSBL) of the FRISC-V reference design.
 * It is an auto-generated file placed at the reset vector (RESET_VEC=ZSBL_BASE) if ZSBL is enabled (ZSBL_ROM_SIZE_BYTES > 0).
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_zsbl_rom (
    input  logic  i_clk,
    input  addr_t i_addr,
    output inst_t o_data
);

(* ram_style = "block" *) inst_t mem [ZSBL_ROM_SIZE_BYTES/4];
localparam int unsigned ZSBL_PROG_WORDS = 0;

logic [31:0] w_word_offset;
logic        w_valid;
inst_t       r_data;

assign w_word_offset = (i_addr - RESET_VEC) >> 2;
assign w_valid = (i_addr >= RESET_VEC && w_word_offset < (ZSBL_ROM_SIZE_BYTES/4));

// Registered read for BRAM inference
always_ff @(posedge i_clk) begin
    // Do not reset r_data, will not synthesize as BRAM if reset added
    if (w_valid) begin
        r_data <= mem[w_word_offset];
    end else begin
        r_data <= NOP;
    end
end

assign o_data = r_data;

initial begin
    // Auto-generated program at RESET_VEC (0x1000)

    for (int i = ZSBL_PROG_WORDS; i < (ZSBL_ROM_SIZE_BYTES/4); i++) begin
        mem[i] = 32'h0000_0000;
    end
end

endmodule

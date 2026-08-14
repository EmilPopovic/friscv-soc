// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
//
// Matej Jurasić <matej.jurasic@cappig.dev>

module vernii_zsbl_rom import vernii_pkg::*; #(
    parameter int unsigned ProgWords = 1,
    parameter logic [31:0] Prog [ProgWords] = '{default: '0},
    parameter logic [31:0] BaseAddr  = 32'h0020_0000,
    parameter type         reg_req_t = vernii_reg_req_t,
    parameter type         reg_rsp_t = vernii_reg_rsp_t
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  reg_req_t reg_req_i,
    output reg_rsp_t reg_rsp_o
);

// Decoded window rounded up to the next power of 2
localparam int unsigned Words    = 32'd1 << $clog2(ProgWords);
localparam int unsigned OffsetW  = (Words > 1) ? $clog2(Words) : 1;
localparam logic [31:0] NopInst  = 32'h0000_0013;  // addi x0,x0,0

logic [31:0] mem [Words];

for (genvar i = 0; i < Words; i++) begin : gen_mem
    if (i < ProgWords) begin : gen_prog
        assign mem[i] = Prog[i];
    end else begin : gen_pad
        assign mem[i] = 32'h0000_0000;
    end
end

logic [OffsetW-1:0] w_offset;
assign w_offset = OffsetW'((reg_req_i.addr - BaseAddr) >> 2);

logic w_read;
assign w_read = reg_req_i.valid && !reg_req_i.write;

// The read is registered, so it answers on the cycle after the request lands
logic r_done;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        r_done            <= 1'b0;
        reg_rsp_o.rdata   <= NopInst;
    end else begin
        r_done            <= w_read && !r_done;
        reg_rsp_o.rdata   <= mem[w_offset];
    end
end

assign reg_rsp_o.ready = r_done || (reg_req_i.valid && reg_req_i.write);
assign reg_rsp_o.error = reg_req_i.valid && reg_req_i.write;

endmodule

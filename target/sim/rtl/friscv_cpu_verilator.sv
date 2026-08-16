// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
//
// Emil Popović <mail@emilpopovic.me>
// Matej Jurasić <matej.jurasic@cappig.dev>

module friscv_cpu_verilator import friscv_mem_pkg::*; (
    input  logic        clk_i,
    input  logic        rst_ni,
    output logic        halt_o,

    input  logic        msip_i,
    input  logic        mtip_i,
    input  logic        meip_i,

    input  logic [63:0] mtime_i,

    output logic [1:0]  size_o,
    output logic [31:0] addr_o,
    output logic [31:0] wdata_o,
    input  logic [31:0] rdata_i,
    output logic        w_en_o,
    output logic        r_en_o,
    input  logic        stall_i,
    output logic        burst_en_o,
    input  logic        beat_valid_i,
    input  logic        err_i
);

friscv_mem_req_t mem_req;
friscv_mem_rsp_t mem_rsp;

assign size_o     = mem_req.size;
assign addr_o     = mem_req.addr;
assign wdata_o    = mem_req.wdata;
assign w_en_o     = mem_req.en &&  mem_req.wr;
assign r_en_o     = mem_req.en && !mem_req.wr;
assign burst_en_o = mem_req.burst;

assign mem_rsp.rdata = rdata_i;
assign mem_rsp.stall = stall_i;
assign mem_rsp.beat  = beat_valid_i;
assign mem_rsp.err   = err_i;

friscv #(
    .ResetVec         ( 32'h8000_0000 ),
    .HaltOnEndAddress ( 1             )
) core (
    .clk_i,
    .rst_ni,
    .end_o     ( halt_o  ),
    .msip_i,
    .mtip_i,
    .meip_i,
    .seip_i    ( 1'b0    ),
    .mtime_i,
    .mem_req_o ( mem_req ),
    .mem_rsp_i ( mem_rsp ),
    .dbg_req_i ( 1'b0    )
);

endmodule

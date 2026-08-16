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
    input  logic        clk,
    input  logic        rstn,
    output logic        halt,

    input  logic        msip,
    input  logic        mtip,
    input  logic        meip,

    input  logic [63:0] mtime,

    output logic [1:0]  size,
    output logic [31:0] addr,
    output logic [31:0] wdata,
    input  logic [31:0] rdata,
    output logic        w_en,
    output logic        r_en,
    input  logic        stall,
    output logic        burst_en,
    input  logic        beat_valid,
    input  logic        err
);

friscv_mem_req_t mem_req;
friscv_mem_rsp_t mem_rsp;

assign size     = mem_req.size;
assign addr     = mem_req.addr;
assign wdata    = mem_req.wdata;
assign w_en     = mem_req.en &&  mem_req.wr;
assign r_en     = mem_req.en && !mem_req.wr;
assign burst_en = mem_req.burst;

assign mem_rsp.rdata = rdata;
assign mem_rsp.stall = stall;
assign mem_rsp.beat  = beat_valid;
assign mem_rsp.err   = err;

friscv #(
    .ResetVec         ( 32'h8000_0000 ),
    .HaltOnEndAddress ( 1             )
) core (
    .clk_i     ( clk   ),
    .rst_ni    ( rstn  ),
    .end_o     ( halt  ),
    .msip_i    ( msip  ),
    .mtip_i    ( mtip  ),
    .meip_i    ( meip  ),
    .seip_i    ( 1'b0  ),
    .mtime_i   ( mtime   ),
    .mem_req_o ( mem_req ),
    .mem_rsp_i ( mem_rsp ),
    .dbg_req_i ( 1'b0    )
);

endmodule

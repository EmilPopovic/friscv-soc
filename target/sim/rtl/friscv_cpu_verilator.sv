// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

`timescale 1ns / 1ps

module friscv_cpu_verilator (
    input  logic        clk,
    input  logic        rstn,
    output logic        halt,
    
    input  logic        msip,
    input  logic        mtip,
    input  logic        meip,

    input  logic [63:0] mtime,

    output logic [2:0]  size,
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

friscv_mem_if mem ();

assign size = mem.size;
assign addr = mem.addr;
assign wdata = mem.wdata;
assign w_en = mem.rw[0];
assign r_en = mem.rw[1];
assign burst_en = mem.burst_en;

assign mem.rdata = rdata;
assign mem.wait_req = stall;
assign mem.beat_valid = beat_valid;
assign mem.err = err;

friscv_cpu_subsystem_core #(
    .RAM_BASE                   ( 32'h8000_0000 ),
    .ZSBL_ROM_SIZE_BYTES        ( 0             ),
    .ENABLE_HALT_ON_END_ADDRESS ( 1             )
) core (
    .i_clk     ( clk   ),
    .i_rstn    ( rstn  ),
    .o_end     ( halt  ),
    .i_msip    ( msip  ),
    .i_mtip    ( mtip  ),
    .i_meip    ( meip  ),
    .i_seip    ( 1'b0  ),
    .i_mtime   ( mtime ),
    .mem_if    ( mem   ),
    .i_dbg_req ( 1'b0  )
);

endmodule

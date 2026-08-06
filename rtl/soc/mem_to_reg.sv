// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

`timescale 1ns/1ps

module mem_to_reg #(
    parameter int unsigned AW        = 32,
    parameter int unsigned DW        = 32,
    parameter type         reg_req_t = logic,
    parameter type         reg_rsp_t = logic
) (
    input  logic            clk_i,
    input  logic            rst_ni,

    // Mem in
    input  logic            req_i,
    output logic            gnt_o,
    input  logic            we_i,
    input  logic [AW-1:0]   addr_i,
    input  logic [DW-1:0]   wdata_i,
    input  logic [DW/8-1:0] be_i,
    output logic [DW-1:0]   rdata_o,
    output logic            rvalid_o,
    output logic            err_o,

    // Reg out
    output reg_req_t        reg_req_o,
    input  reg_rsp_t        reg_rsp_i
);

logic w_hs;
assign w_hs = req_i && reg_rsp_i.ready;

assign gnt_o = w_hs;

assign reg_req_o.valid = req_i;
assign reg_req_o.addr  = addr_i;
assign reg_req_o.write = we_i;
assign reg_req_o.wdata = wdata_i;
assign reg_req_o.wstrb = be_i;

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        rvalid_o <= 1'b0;
        rdata_o  <= '0;
        err_o    <= 1'b0;
    end else begin
        rvalid_o <= w_hs;
        if (w_hs) begin
            rdata_o <= reg_rsp_i.rdata;
            err_o   <= reg_rsp_i.error;
        end
    end
end

endmodule

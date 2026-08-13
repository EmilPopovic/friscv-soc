// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
//
// Emil Popović <mail@emilpopovic.me>

/*
 * System Control Block
 */

module vernii_scb import vernii_pkg::*; #(
    parameter int unsigned NumPads    = 25,
    parameter int unsigned OcmLlcWays = 4,
    parameter type         reg_req_t  = vernii_reg_req_t,
    parameter type         reg_rsp_t  = vernii_reg_rsp_t
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  reg_req_t reg_req_i,
    output reg_rsp_t reg_rsp_o,

    input  logic [NumPads-1:0] strap_i,

    output logic [OcmLlcWays-1:0] llcsel_o,
    output logic                  crpsel_o,
    output logic                  llcinv_o
);

// Byte offsets within the block's register page
localparam logic [11:0] OFF_SCRATCH0 = 12'h000;
localparam logic [11:0] OFF_STRAPA   = 12'h004;
localparam logic [11:0] OFF_LLCSEL   = 12'h00C;
localparam logic [11:0] OFF_CRPSEL   = 12'h010;
localparam logic [11:0] OFF_LLCINV   = 12'h014;

logic [11:0] off;
assign off = reg_req_i.addr[11:0];

logic do_write;
assign do_write = reg_req_i.valid && reg_req_i.write;

// ============================================================
// Registers
// ============================================================

logic [31:0]           r_scratch0;  // SCRATCH0
logic                  r_strapped;  // STRAPA sampled flag
logic [2:0]            r_strap_dly;
logic [NumPads-1:0]    r_strapa;    // STRAPA
logic [OcmLlcWays-1:0] r_llcsel;    // LLCSEL
logic                  r_crpsel;    // CRPSEL
logic                  r_llcinv;    // LLCINV

logic [NumPads-1:0] strap_sync;

for (genvar i = 0; i < NumPads; i++) begin : gen_strap_sync
    tc_sync #(
        .Stages     ( 2    ),
        .ResetValue ( 1'b0 )
    ) sync_strap (
        .clk_i,
        .rst_ni,
        .serial_i ( strap_i[i]   ),
        .serial_o ( strap_sync[i])
    );
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        r_scratch0  <= 32'h0;
        r_strapped  <= 1'b0;
        r_strap_dly <= 3'h0;
        r_strapa    <= '0;
        r_llcsel    <= '0;
        r_crpsel    <= '0;
        r_llcinv    <= 1'b0;
    end else begin
        // Write one to request an invalidate, then self-clear
        r_llcinv <= do_write && off == OFF_LLCINV && reg_req_i.wstrb[0] && reg_req_i.wdata[0];

        // Capture the pad inputs once, on the first cycle out of reset
        if (!r_strapped) begin
            r_strap_dly <= r_strap_dly + 1'b1;
            if (&r_strap_dly) begin
                r_strapa   <= strap_sync;
                r_strapped <= 1'b1;
            end
        end

        if (do_write && off == OFF_SCRATCH0) begin
            for (int i = 0; i < 4; i++) begin
                if (reg_req_i.wstrb[i])
                    r_scratch0[8*i +: 8] <= reg_req_i.wdata[8*i +: 8];
            end
        end

        if (do_write && off == OFF_LLCSEL && reg_req_i.wstrb[0]) begin
            r_llcsel <= reg_req_i.wdata[OcmLlcWays-1:0];
        end

        if (do_write && off == OFF_CRPSEL && reg_req_i.wstrb[0]) begin
            r_crpsel <= reg_req_i.wdata[0];
        end
    end
end

assign llcsel_o = r_llcsel;
assign crpsel_o = r_crpsel;
assign llcinv_o = r_llcinv;

// ============================================================
// Read / response
// ============================================================

logic [31:0] rdata;
logic        map_err;

always_comb begin
    rdata   = 32'h0;
    map_err = 1'b0;
    case (off)
        OFF_SCRATCH0: rdata = r_scratch0;
        OFF_STRAPA:   rdata = 32'(r_strapa);
        OFF_LLCSEL:   rdata = {{32-OcmLlcWays{1'b0}}, {r_llcsel}};
        OFF_CRPSEL:   rdata = {31'h0, r_crpsel};
        OFF_LLCINV:   rdata = 32'h0;   // write-only, the invalidate is done by the time the store retires
        default:      map_err = 1'b1;
    endcase
end

assign reg_rsp_o.rdata = rdata;
assign reg_rsp_o.ready = 1'b1;
assign reg_rsp_o.error = reg_req_i.valid && map_err;

endmodule

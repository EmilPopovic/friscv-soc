// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * Bridge between the riscv-dbg System Bus Access (SBA) master port and an
 * AXI4-Lite master interface.
 */

`timescale 1ns / 1ps

module friscv_dm_sba_axi #(
    parameter int unsigned AxiAddrWidth = 32,
    parameter int unsigned AxiDataWidth = 32
) (
    input  logic i_clk,
    input  logic i_rstn,

    // riscv-dbg SBA master side
    input  logic                      dm_req_i,
    input  logic [AxiAddrWidth-1:0]   dm_addr_i,
    input  logic                      dm_we_i,
    input  logic [AxiDataWidth-1:0]   dm_wdata_i,
    input  logic [AxiDataWidth/8-1:0] dm_be_i,
    output logic                      dm_gnt_o,
    output logic                      dm_rvalid_o,
    output logic                      dm_err_o,
    output logic                      dm_other_err_o,
    output logic [AxiDataWidth-1:0]   dm_rdata_o,

    // AXI4-Lite master side
    AXI_LITE.Master                   mst
);

    localparam int unsigned StrbWidth = AxiDataWidth/8;

    typedef enum logic [2:0] {
        S_IDLE,
        S_W,
        S_W_RESP,
        S_R_ADDR,
        S_R_DATA
    } state_e;

    state_e state_q, state_d;

    // Latched transaction fields
    logic [AxiAddrWidth-1:0] addr_q;
    logic [AxiDataWidth-1:0] wdata_q;
    logic [StrbWidth-1:0]    be_q;
    logic                    aw_done_q;
    logic                    w_done_q;

    // Constant AXI request fields
    assign mst.aw_addr   = addr_q;
    assign mst.aw_prot   = 3'b000;

    assign mst.w_data    = wdata_q;
    assign mst.w_strb    = be_q;

    assign mst.ar_addr   = addr_q;
    assign mst.ar_prot   = 3'b000;

    // Read data / errors returned to the DM
    assign dm_rdata_o     = mst.r_data;
    assign dm_other_err_o = 1'b0;

    always_comb begin
        state_d      = state_q;

        dm_gnt_o     = 1'b0;
        dm_rvalid_o  = 1'b0;
        dm_err_o     = 1'b0;

        mst.aw_valid = 1'b0;
        mst.w_valid  = 1'b0;
        mst.b_ready  = 1'b0;
        mst.ar_valid = 1'b0;
        mst.r_ready  = 1'b0;

        unique case (state_q)
            S_IDLE: begin
                dm_gnt_o = dm_req_i;
                if (dm_req_i) state_d = dm_we_i ? S_W : S_R_ADDR;
            end

            S_W: begin
                mst.aw_valid = !aw_done_q;
                mst.w_valid  = !w_done_q;
                if ((aw_done_q || mst.aw_ready) &&
                    (w_done_q || mst.w_ready))
                    state_d = S_W_RESP;
            end

            S_W_RESP: begin
                mst.b_ready = 1'b1;
                if (mst.b_valid) begin
                    dm_rvalid_o = 1'b1;
                    dm_err_o    = |mst.b_resp;
                    state_d     = S_IDLE;
                end
            end

            S_R_ADDR: begin
                mst.ar_valid = 1'b1;
                if (mst.ar_ready) state_d = S_R_DATA;
            end

            S_R_DATA: begin
                mst.r_ready = 1'b1;
                if (mst.r_valid) begin
                    dm_rvalid_o = 1'b1;
                    dm_err_o    = |mst.r_resp;
                    state_d     = S_IDLE;
                end
            end

            default: state_d = S_IDLE;
        endcase
    end

    always_ff @(posedge i_clk) begin
        if (!i_rstn) begin
            state_q   <= S_IDLE;
            addr_q    <= '0;
            wdata_q   <= '0;
            be_q      <= '0;
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
        end else begin
            state_q <= state_d;
            if (state_q == S_IDLE && dm_req_i) begin
                addr_q    <= dm_addr_i;
                wdata_q   <= dm_wdata_i;
                be_q      <= dm_be_i;
                aw_done_q <= 1'b0;
                w_done_q  <= 1'b0;
            end
            if (state_q == S_W) begin
                if (mst.aw_valid && mst.aw_ready) aw_done_q <= 1'b1;
                if (mst.w_valid && mst.w_ready)   w_done_q  <= 1'b1;
            end
        end
    end

endmodule

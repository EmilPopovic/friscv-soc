// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements a simple 1-entry buffer between the core/MMU and the AMO unit and external bus.
 * This is used to meet timing requirements, as it decouples the core from the external bus logic,
 * but introduces two cycles of latency for memory operations.
 *
 * Configurable using the ENABLE_L2_BUFFER parameter of friscv_core_complex.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_l2_buffer (
    input logic i_clk,
    input logic i_rstn,
    friscv_l2_if.responder if_upstream,
    friscv_l2_if.requester if_downstream
);

logic       r_valid;
addr_t      r_addr;
mem_width_e r_size;
data_t      r_wdata;
rw_cmd_e    r_rw;
amo_op_e    r_amo_op;

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_valid  <= 1'b0;
        r_addr   <= '0;
        r_size   <= WIDTH_I32;
        r_wdata  <= '0;
        r_rw     <= RW_IDLE;
        r_amo_op <= AMO_NONE;
    end else begin
        // Complete a buffered request once the downstream interface stops stalling.
        if (r_valid && !if_downstream.stall) begin
            r_valid <= 1'b0;
        // Capture a new request when the buffer is empty.
        end else if (!r_valid && if_upstream.valid) begin
            r_valid  <= 1'b1;
            r_addr   <= if_upstream.addr;
            r_size   <= if_upstream.size;
            r_wdata  <= if_upstream.wdata;
            r_rw     <= if_upstream.rw;
            r_amo_op <= if_upstream.amo_op;
        end
    end
end

assign if_upstream.stall = r_valid ? if_downstream.stall : if_upstream.valid;
assign if_upstream.err   = if_downstream.err;
assign if_upstream.rdata = if_downstream.rdata;

assign if_downstream.valid  = r_valid;
assign if_downstream.addr   = r_addr;
assign if_downstream.size   = r_size;
assign if_downstream.wdata  = r_wdata;
assign if_downstream.rw     = r_valid ? r_rw     : RW_IDLE;
assign if_downstream.amo_op = r_valid ? r_amo_op : AMO_NONE;

endmodule

// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

`timescale 1ns/1ps

module friscv_axi_lite_adapter_intf (
    input  logic        clk_i,
    input  logic        rst_ni,
    friscv_mem_if.slave mem_slv,
    AXI_LITE.Master     mst
);

// AW channel
logic        m_axi_awvalid;
logic        m_axi_awready;
logic [31:0] m_axi_awaddr;
logic [2:0]  m_axi_awprot;

assign mst.aw_addr   = m_axi_awaddr;
assign mst.aw_prot   = m_axi_awprot;
assign mst.aw_valid  = m_axi_awvalid;
assign m_axi_awready = mst.aw_ready;

// W channel
logic        m_axi_wvalid;
logic        m_axi_wready;
logic [31:0] m_axi_wdata;
logic [3:0]  m_axi_wstrb;

assign mst.w_data    = m_axi_wdata;
assign mst.w_strb    = m_axi_wstrb;
assign mst.w_valid   = m_axi_wvalid;
assign m_axi_wready  = mst.w_ready;

// B channel
logic        m_axi_bvalid;
logic        m_axi_bready;
logic [1:0]  m_axi_bresp;

assign m_axi_bresp   = mst.b_resp;
assign m_axi_bvalid  = mst.b_valid;
assign mst.b_ready   = m_axi_bready;

// AR channel
logic        m_axi_arvalid;
logic        m_axi_arready;
logic [31:0] m_axi_araddr;
logic [2:0]  m_axi_arprot;

assign mst.ar_addr   = m_axi_araddr;
assign mst.ar_prot   = m_axi_arprot;
assign mst.ar_valid  = m_axi_arvalid;
assign m_axi_arready = mst.ar_ready;

// R channel
logic        m_axi_rvalid;
logic        m_axi_rready;
logic [31:0] m_axi_rdata;
logic [1:0]  m_axi_rresp;

assign m_axi_rdata   = mst.r_data;
assign m_axi_rresp   = mst.r_resp;
assign m_axi_rvalid  = mst.r_valid;
assign mst.r_ready   = m_axi_rready;

friscv_axi_lite_adapter m_soc (
    .i_clk          ( clk_i         ),
    .i_rstn         ( rst_ni        ),
    .mem_if         ( mem_slv       ),
    .m_axi_awvalid  ( m_axi_awvalid ),
    .m_axi_awready  ( m_axi_awready ),
    .m_axi_awaddr   ( m_axi_awaddr  ),
    .m_axi_awprot   ( m_axi_awprot  ),
    .m_axi_wvalid   ( m_axi_wvalid  ),
    .m_axi_wready   ( m_axi_wready  ),
    .m_axi_wdata    ( m_axi_wdata   ),
    .m_axi_wstrb    ( m_axi_wstrb   ),
    .m_axi_bvalid   ( m_axi_bvalid  ),
    .m_axi_bready   ( m_axi_bready  ),
    .m_axi_bresp    ( m_axi_bresp   ),
    .m_axi_arvalid  ( m_axi_arvalid ),
    .m_axi_arready  ( m_axi_arready ),
    .m_axi_araddr   ( m_axi_araddr  ),
    .m_axi_arprot   ( m_axi_arprot  ),
    .m_axi_rvalid   ( m_axi_rvalid  ),
    .m_axi_rready   ( m_axi_rready  ),
    .m_axi_rdata    ( m_axi_rdata   ),
    .m_axi_rresp    ( m_axi_rresp   )
);

endmodule

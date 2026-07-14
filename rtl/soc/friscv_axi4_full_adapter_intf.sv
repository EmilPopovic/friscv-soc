// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

`timescale 1ns/1ps

module friscv_axi4_full_adapter_intf #(
    parameter int unsigned AXI_ID_WIDTH   = 1,
    parameter int unsigned AXI_USER_WIDTH = 1
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    friscv_mem_if.slave mem_slv,
    AXI_BUS.Master      mst
);

friscv_axi4_full_adapter #(
    .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
    .AXI_USER_WIDTH ( AXI_USER_WIDTH )
) m_axi (
    .i_clk          ( clk_i         ),
    .i_rstn         ( rst_ni        ),
    .mem_if         ( mem_slv       ),
    .m_axi_awvalid  ( mst.aw_valid  ),
    .m_axi_awready  ( mst.aw_ready  ),
    .m_axi_awid     ( mst.aw_id     ),
    .m_axi_awaddr   ( mst.aw_addr   ),
    .m_axi_awsize   ( mst.aw_size   ),
    .m_axi_awcache  ( mst.aw_cache  ),
    .m_axi_awprot   ( mst.aw_prot   ),
    .m_axi_awburst  ( mst.aw_burst  ),
    .m_axi_awlen    ( mst.aw_len    ),
    .m_axi_awlock   ( mst.aw_lock   ),
    .m_axi_awqos    ( mst.aw_qos    ),
    .m_axi_awregion ( mst.aw_region ),
    .m_axi_awatop   ( mst.aw_atop   ),
    .m_axi_awuser   ( mst.aw_user   ),
    .m_axi_wvalid   ( mst.w_valid   ),
    .m_axi_wready   ( mst.w_ready   ),
    .m_axi_wlast    ( mst.w_last    ),
    .m_axi_wdata    ( mst.w_data    ),
    .m_axi_wstrb    ( mst.w_strb    ),
    .m_axi_wuser    ( mst.w_user    ),
    .m_axi_bvalid   ( mst.b_valid   ),
    .m_axi_bready   ( mst.b_ready   ),
    .m_axi_bresp    ( mst.b_resp    ),
    .m_axi_arvalid  ( mst.ar_valid  ),
    .m_axi_arready  ( mst.ar_ready  ),
    .m_axi_arid     ( mst.ar_id     ),
    .m_axi_araddr   ( mst.ar_addr   ),
    .m_axi_arsize   ( mst.ar_size   ),
    .m_axi_arcache  ( mst.ar_cache  ),
    .m_axi_arprot   ( mst.ar_prot   ),
    .m_axi_arburst  ( mst.ar_burst  ),
    .m_axi_arlen    ( mst.ar_len    ),
    .m_axi_arlock   ( mst.ar_lock   ),
    .m_axi_arqos    ( mst.ar_qos    ),
    .m_axi_arregion ( mst.ar_region ),
    .m_axi_aruser   ( mst.ar_user   ),
    .m_axi_rvalid   ( mst.r_valid   ),
    .m_axi_rready   ( mst.r_ready   ),
    .m_axi_rlast    ( mst.r_last    ),
    .m_axi_rdata    ( mst.r_data    ),
    .m_axi_rresp    ( mst.r_resp    )
);

endmodule

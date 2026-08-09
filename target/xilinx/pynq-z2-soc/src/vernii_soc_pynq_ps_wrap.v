// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

module vernii_soc_pynq_ps_wrap #(
    parameter SramBase  = 32'h8000_0000,
    parameter SramSize  = 32'h0008_0000,
    parameter MemBase   = 32'h8000_0000,
    parameter MemSize   = 32'h0100_0000,
    parameter MemPsBase = 32'h0010_0000,
    parameter ZsblRom   = 1,
    parameter NumGpio   = 27,
    parameter NumStraps = 13
) (
    // Without the association the block design cannot tell what clocks m_axi,
    // defaults it to 100 MHz and fails validation against the interconnect
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_i CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axi, ASSOCIATED_RESET rstn_i" *)
    input  wire clk_i,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rstn_i RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire rstn_i,

    output wire [3:0] led_o,

    input  wire jtag_tck_i,
    input  wire jtag_tms_i,
    input  wire jtag_tdi_i,
    output wire jtag_tdo_o,

    input  wire uart_rx_i,
    output wire uart_tx_o,

    output wire qspi_sck_o,
    output wire [2:0] qspi_cs_o,
    inout  wire [3:0] qspi_sd_io,

    inout  wire [NumGpio-1:0] gpio_io,

    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire [0:0]  m_axi_awlock,
    output wire [3:0]  m_axi_awcache,
    output wire [2:0]  m_axi_awprot,
    output wire [3:0]  m_axi_awqos,
    output wire [0:0]  m_axi_awid,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,

    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,

    input  wire [1:0]  m_axi_bresp,
    input  wire [0:0]  m_axi_bid,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire [0:0]  m_axi_arlock,
    output wire [3:0]  m_axi_arcache,
    output wire [2:0]  m_axi_arprot,
    output wire [3:0]  m_axi_arqos,
    output wire [0:0]  m_axi_arid,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,

    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire [0:0]  m_axi_rid,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready
);

vernii_soc_pynq_ps #(
    .SramBase  ( SramBase  ),
    .SramSize  ( SramSize  ),
    .MemBase   ( MemBase   ),
    .MemSize   ( MemSize   ),
    .MemPsBase ( MemPsBase ),
    .ZsblRom   ( ZsblRom   ),
    .NumGpio   ( NumGpio   ),
    .NumStraps ( NumStraps )
) i_vernii_soc_pynq_ps (
    .clk_i  ( clk_i  ),
    .rstn_i ( rstn_i ),

    .led_o ( led_o ),

    .jtag_tck_i ( jtag_tck_i ),
    .jtag_tms_i ( jtag_tms_i ),
    .jtag_tdi_i ( jtag_tdi_i ),
    .jtag_tdo_o ( jtag_tdo_o ),

    .uart_rx_i ( uart_rx_i ),
    .uart_tx_o ( uart_tx_o ),

    .qspi_sck_o ( qspi_sck_o ),
    .qspi_cs_o  ( qspi_cs_o  ),
    .qspi_sd_io ( qspi_sd_io ),

    .gpio_io ( gpio_io ),

    .m_axi_awaddr  ( m_axi_awaddr  ),
    .m_axi_awlen   ( m_axi_awlen   ),
    .m_axi_awsize  ( m_axi_awsize  ),
    .m_axi_awburst ( m_axi_awburst ),
    .m_axi_awlock  ( m_axi_awlock  ),
    .m_axi_awcache ( m_axi_awcache ),
    .m_axi_awprot  ( m_axi_awprot  ),
    .m_axi_awqos   ( m_axi_awqos   ),
    .m_axi_awid    ( m_axi_awid    ),
    .m_axi_awvalid ( m_axi_awvalid ),
    .m_axi_awready ( m_axi_awready ),

    .m_axi_wdata  ( m_axi_wdata  ),
    .m_axi_wstrb  ( m_axi_wstrb  ),
    .m_axi_wlast  ( m_axi_wlast  ),
    .m_axi_wvalid ( m_axi_wvalid ),
    .m_axi_wready ( m_axi_wready ),

    .m_axi_bresp  ( m_axi_bresp  ),
    .m_axi_bid    ( m_axi_bid    ),
    .m_axi_bvalid ( m_axi_bvalid ),
    .m_axi_bready ( m_axi_bready ),

    .m_axi_araddr  ( m_axi_araddr  ),
    .m_axi_arlen   ( m_axi_arlen   ),
    .m_axi_arsize  ( m_axi_arsize  ),
    .m_axi_arburst ( m_axi_arburst ),
    .m_axi_arlock  ( m_axi_arlock  ),
    .m_axi_arcache ( m_axi_arcache ),
    .m_axi_arprot  ( m_axi_arprot  ),
    .m_axi_arqos   ( m_axi_arqos   ),
    .m_axi_arid    ( m_axi_arid    ),
    .m_axi_arvalid ( m_axi_arvalid ),
    .m_axi_arready ( m_axi_arready ),

    .m_axi_rdata  ( m_axi_rdata  ),
    .m_axi_rresp  ( m_axi_rresp  ),
    .m_axi_rid    ( m_axi_rid    ),
    .m_axi_rlast  ( m_axi_rlast  ),
    .m_axi_rvalid ( m_axi_rvalid ),
    .m_axi_rready ( m_axi_rready )
);

endmodule

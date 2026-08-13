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

`default_nettype none

module vernii_soc_pynq_ps import vernii_pkg::*, axi_pkg::xbar_rule_32_t; #(
    parameter int unsigned OcmBase   = 32'h0000_0000,
    parameter int unsigned OcmSize   = 32'h0008_0000,
    parameter int unsigned ExtBase   = 32'h8000_0000,
    parameter int unsigned ExtSize   = 32'h0100_0000,
    parameter int unsigned MemPsBase = 32'h0010_0000,
    parameter int unsigned ZsblRom   = 1,
    parameter int unsigned NumGpio   = 27,
    parameter int unsigned NumStraps = 8
) (
    input  wire clk_i,
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

localparam int unsigned RstCntW = 10;

logic [RstCntW-1:0] rst_cnt;
logic               soc_rstn;

always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
        rst_cnt  <= '0;
        soc_rstn <= 1'b0;
    end else if (rst_cnt != {RstCntW{1'b1}}) begin
        rst_cnt  <= rst_cnt + 1'b1;
        soc_rstn <= 1'b0;
    end else begin
        soc_rstn <= 1'b1;
    end
end

logic [23:0] heartbeat_cnt;
always_ff @(posedge clk_i) begin
    heartbeat_cnt <= heartbeat_cnt + 1'b1;
end

logic soc_end;

assign led_o[0] = soc_end;           // LD5 green: program signalled completion
assign led_o[1] = 1'b1;              // LD4 blue:  bitstream configured
assign led_o[2] = ~soc_rstn;         // LD4 red:   SoC held in reset
assign led_o[3] = heartbeat_cnt[23]; // LD4 green: free-running heartbeat

vernii_axi_req_t  axi_req;
vernii_axi_resp_t axi_rsp;

vernii_reg_req_t [0:0] reg_ext_req;
vernii_reg_rsp_t [0:0] reg_ext_rsp;

assign reg_ext_rsp[0].rdata = '0;
assign reg_ext_rsp[0].error = 1'b0;
assign reg_ext_rsp[0].ready = 1'b1;

localparam xbar_rule_32_t [0:0] ExtRegSlvRules = '{
    '{ idx: 0, start_addr: 32'h4000_1000, end_addr: 32'h4000_2000 }
};

logic [31:0] gpio_in, gpio_out, gpio_oe;

logic       qspi_sck, qspi_sck_oe;
logic [2:0] qspi_cs,  qspi_cs_oe;
logic [3:0] qspi_sd_i, qspi_sd_o, qspi_sd_oe;

// Disable the first 6 GPIOs (0-5) as inputs only to not damage the board
localparam logic [31:0] GpioInOnly = 32'h0000_003F;

logic [31:0] gpio_oe_eff;
assign gpio_oe_eff = gpio_oe & ~GpioInOnly;

for (genvar i = 0; i < NumGpio; i++) begin : gen_gpio_pads
    IOBUF i_iobuf (
        .O  (  gpio_in    [i] ),
        .IO (  gpio_io    [i] ),
        .I  (  gpio_out   [i] ),
        .T  ( ~gpio_oe_eff[i] )
    );
end

assign gpio_in[31:NumGpio] = '0;

for (genvar i = 0; i < 4; i++) begin : gen_qspi_pads
    IOBUF i_iobuf (
        .O  (  qspi_sd_i [i] ),
        .IO (  qspi_sd_io[i] ),
        .I  (  qspi_sd_o [i] ),
        .T  ( ~qspi_sd_oe[i] )
    );
end

assign qspi_sck_o = qspi_sck;
assign qspi_cs_o  = qspi_cs;

`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
vernii_soc #(
    .OcmBase          ( OcmBase        ),
    .OcmSize          ( OcmSize        ),
    .ExtBase          ( ExtBase        ),
    .ExtSize          ( ExtSize        ),
    .ZsblRomEnable    ( ZsblRom != 0                     ),
    .NumStraps        ( NumStraps      ),
    .NumExtRegSlv     ( 1              ),
    .ExtRegSlvRules   ( ExtRegSlvRules ),
    .HaltOnEnd        ( 1'b1           )
) i_vernii_soc (
    .clk_i          ( clk_i                  ),
    .rst_ni         ( soc_rstn               ),
    .test_mode_i    ( 1'b0                   ),
    .por_rst_no     (                        ),
    .soc_rst_no     (                        ),
    .end_o          ( soc_end                ),
    .axi_mem_req_o  ( axi_req                ),
    .axi_mem_rsp_i  ( axi_rsp                ),
    .reg_ext_req_o  ( reg_ext_req            ),
    .reg_ext_rsp_i  ( reg_ext_rsp            ),
    .strap_i        ( gpio_in[NumStraps-1:0] ),
    .uart0_rx_i     ( uart_rx_i              ),
    .uart0_tx_o     ( uart_tx_o              ),
    .jtag_tck_i     ( jtag_tck_i             ),
    .jtag_tms_i     ( jtag_tms_i             ),
    .jtag_trst_ni   ( 1'b1                   ),
    .jtag_tdi_i     ( jtag_tdi_i             ),
    .jtag_tdo_o     ( jtag_tdo_o             ),
    .jtag_tdo_oe_o  (                        ),
    .qspi0_sck_o    ( qspi_sck               ),
    .qspi0_sck_oe_o ( qspi_sck_oe            ),
    .qspi0_cs_o     ( qspi_cs                ),
    .qspi0_cs_oe_o  ( qspi_cs_oe             ),
    .qspi0_sd_o     ( qspi_sd_o              ),
    .qspi0_sd_oe_o  ( qspi_sd_oe             ),
    .qspi0_sd_i     ( qspi_sd_i              ),
    .ext_irq_i      ( '0                     ),
    .gpio_a_i       ( gpio_in                ),
    .gpio_a_o       ( gpio_out               ),
    .gpio_a_oe_o    ( gpio_oe                )
);
`pragma diagnostic pop

assign m_axi_awaddr  = axi_req.aw.addr - ExtBase + MemPsBase;
assign m_axi_awlen   = axi_req.aw.len;
assign m_axi_awsize  = axi_req.aw.size;
assign m_axi_awburst = axi_req.aw.burst;
assign m_axi_awlock  = '0;
assign m_axi_awcache = axi_req.aw.cache;
assign m_axi_awprot  = axi_req.aw.prot;
assign m_axi_awqos   = axi_req.aw.qos;
assign m_axi_awid    = axi_req.aw.id;
assign m_axi_awvalid = axi_req.aw_valid;

assign m_axi_wdata  = axi_req.w.data;
assign m_axi_wstrb  = axi_req.w.strb;
assign m_axi_wlast  = axi_req.w.last;
assign m_axi_wvalid = axi_req.w_valid;

assign m_axi_bready = axi_req.b_ready;

assign m_axi_araddr  = axi_req.ar.addr - ExtBase + MemPsBase;
assign m_axi_arlen   = axi_req.ar.len;
assign m_axi_arsize  = axi_req.ar.size;
assign m_axi_arburst = axi_req.ar.burst;
assign m_axi_arlock  = '0;
assign m_axi_arcache = axi_req.ar.cache;
assign m_axi_arprot  = axi_req.ar.prot;
assign m_axi_arqos   = axi_req.ar.qos;
assign m_axi_arid    = axi_req.ar.id;
assign m_axi_arvalid = axi_req.ar_valid;

assign m_axi_rready = axi_req.r_ready;

always_comb begin
    axi_rsp          = '0;
    axi_rsp.aw_ready = m_axi_awready;
    axi_rsp.w_ready  = m_axi_wready;
    axi_rsp.b_valid  = m_axi_bvalid;
    axi_rsp.b.id     = m_axi_bid;
    axi_rsp.b.resp   = m_axi_bresp;
    axi_rsp.ar_ready = m_axi_arready;
    axi_rsp.r_valid  = m_axi_rvalid;
    axi_rsp.r.id     = m_axi_rid;
    axi_rsp.r.data   = m_axi_rdata;
    axi_rsp.r.resp   = m_axi_rresp;
    axi_rsp.r.last   = m_axi_rlast;
end

endmodule

`default_nettype wire

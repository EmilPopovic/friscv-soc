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

module vernii_soc_sim import vernii_pkg::*; #(
    parameter int unsigned OcmBase          = 32'h0000_0000,
    parameter int unsigned OcmSize          = 32'h0000_2000,
    parameter int unsigned ExtBase          = 32'h8000_0000,
    parameter int unsigned ExtSize          = 32'h0100_0000,
    parameter int unsigned LineBytes        = 32,
    parameter int unsigned Ways             = 4,
    parameter bit          SramTags         = 1'b1,
    parameter bit          ZsblRomEnable    = 1'b1,
    parameter int unsigned ZsblRomWords     = vernii_zsbl_rom_pkg::ZSBL_PROG_WORDS,
    parameter logic [31:0] ZsblRomProg [ZsblRomWords] = vernii_zsbl_rom_pkg::ZSBL_PROG,
    parameter int unsigned NumStraps        = 8
) (
    input  logic i_clk,
    input  logic i_rstn,

    output logic o_end,

    input  logic i_uart_rx,
    output logic o_uart_tx,

    input  logic i_jtag_tck,
    input  logic i_jtag_tms,
    input  logic i_jtag_trstn,
    input  logic i_jtag_tdi,
    output logic o_jtag_tdo,
    output logic o_jtag_tdo_oe,

    input  logic [NumStraps-1:0] i_strap,

    input  logic [31:0] i_gpio,
    output logic [31:0] o_gpio,
    output logic [31:0] o_gpio_oe,

    output logic       o_qspi_sck,
    output logic       o_qspi_sck_oe,
    output logic [2:0] o_qspi_cs,
    output logic [2:0] o_qspi_cs_oe,
    output logic [3:0] o_qspi_sd,
    output logic [3:0] o_qspi_sd_oe,
    input  logic [3:0] i_qspi_sd,

    output logic        o_axi_aw_valid,
    input  logic        i_axi_aw_ready,
    output logic [31:0] o_axi_aw_addr,
    output logic [7:0]  o_axi_aw_len,
    output logic [2:0]  o_axi_aw_size,
    output logic [1:0]  o_axi_aw_burst,
    output logic        o_axi_aw_id,

    output logic        o_axi_w_valid,
    input  logic        i_axi_w_ready,
    output logic [31:0] o_axi_w_data,
    output logic [3:0]  o_axi_w_strb,
    output logic        o_axi_w_last,

    input  logic        i_axi_b_valid,
    output logic        o_axi_b_ready,
    input  logic [1:0]  i_axi_b_resp,
    input  logic        i_axi_b_id,

    output logic        o_axi_ar_valid,
    input  logic        i_axi_ar_ready,
    output logic [31:0] o_axi_ar_addr,
    output logic [7:0]  o_axi_ar_len,
    output logic [2:0]  o_axi_ar_size,
    output logic [1:0]  o_axi_ar_burst,
    output logic        o_axi_ar_id,

    input  logic        i_axi_r_valid,
    output logic        o_axi_r_ready,
    input  logic [31:0] i_axi_r_data,
    input  logic [1:0]  i_axi_r_resp,
    input  logic        i_axi_r_last,
    input  logic        i_axi_r_id
);

localparam int unsigned PinmuxSlv    = 0;
localparam int unsigned HyperCfgSlv  = 1;
localparam int unsigned NumExtRegSlv = 2;

localparam axi_pkg::xbar_rule_32_t [NumExtRegSlv-1:0] ExtRegSlvRules = '{
    '{ idx: HyperCfgSlv, start_addr: 32'h5001_0000, end_addr: 32'h5001_1000 },
    '{ idx: PinmuxSlv,   start_addr: 32'h4000_1000, end_addr: 32'h4000_2000 }
};

vernii_axi_req_t  axi_req;
vernii_axi_resp_t axi_rsp;

`pragma diagnostic push
`pragma diagnostic ignore="-Wunused-but-set-variable"
vernii_reg_req_t [NumExtRegSlv-1:0] reg_ext_req;
vernii_reg_rsp_t [NumExtRegSlv-1:0] reg_ext_rsp;
`pragma diagnostic pop

for (genvar i = 0; i < NumExtRegSlv; i++) begin : gen_reg_ext_sink
    assign reg_ext_rsp[i].rdata = '0;
    assign reg_ext_rsp[i].error = 1'b0;
    assign reg_ext_rsp[i].ready = 1'b1;
end

`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
vernii_soc #(
    .OcmBase          ( OcmBase          ),
    .OcmSize          ( OcmSize          ),
    .ExtBase          ( ExtBase          ),
    .ExtSize          ( ExtSize          ),
    .LineBytes        ( LineBytes        ),
    .Ways             ( Ways             ),
    .SramTags         ( SramTags         ),
    .ZsblRomEnable    ( ZsblRomEnable    ),
    .ZsblRomWords     ( ZsblRomWords     ),
    .ZsblRomProg      ( ZsblRomProg      ),
    .NumStraps        ( NumStraps        ),
    .NumExtRegSlv     ( NumExtRegSlv     ),
    .ExtRegSlvRules   ( ExtRegSlvRules   ),
    .HaltOnEnd        ( 1                )
) i_vernii_soc (
    .clk_i          ( i_clk         ),
    .rst_ni         ( i_rstn        ),
    .test_mode_i    ( 1'b0          ),
    .por_rst_no     (               ),
    .soc_rst_no     (               ),
    .end_o          ( o_end         ),
    .s_axi_gp_req_i ( '0            ),
    .s_axi_gp_rsp_o (               ),
    .m_axi_hp_req_o ( axi_req       ),
    .m_axi_hp_rsp_i ( axi_rsp       ),
    .reg_ext_req_o  ( reg_ext_req   ),
    .reg_ext_rsp_i  ( reg_ext_rsp   ),
    .strap_i        ( i_strap       ),
    .uart0_rx_i     ( i_uart_rx     ),
    .uart0_tx_o     ( o_uart_tx     ),
    .jtag_tck_i     ( i_jtag_tck    ),
    .jtag_tms_i     ( i_jtag_tms    ),
    .jtag_trst_ni   ( i_jtag_trstn  ),
    .jtag_tdi_i     ( i_jtag_tdi    ),
    .jtag_tdo_o     ( o_jtag_tdo    ),
    .jtag_tdo_oe_o  ( o_jtag_tdo_oe ),
    .qspi0_sck_o    ( o_qspi_sck    ),
    .qspi0_sck_oe_o ( o_qspi_sck_oe ),
    .qspi0_cs_o     ( o_qspi_cs     ),
    .qspi0_cs_oe_o  ( o_qspi_cs_oe  ),
    .qspi0_sd_o     ( o_qspi_sd     ),
    .qspi0_sd_oe_o  ( o_qspi_sd_oe  ),
    .qspi0_sd_i     ( i_qspi_sd     ),
    .ext_irq_i      ( '0            ),
    .gpio_a_i       ( i_gpio        ),
    .gpio_a_o       ( o_gpio        ),
    .gpio_a_oe_o    ( o_gpio_oe     )
);
`pragma diagnostic pop

assign o_axi_aw_valid = axi_req.aw_valid;
assign o_axi_aw_addr  = axi_req.aw.addr;
assign o_axi_aw_len   = axi_req.aw.len;
assign o_axi_aw_size  = axi_req.aw.size;
assign o_axi_aw_burst = axi_req.aw.burst;
assign o_axi_aw_id    = axi_req.aw.id;

assign o_axi_w_valid = axi_req.w_valid;
assign o_axi_w_data  = axi_req.w.data;
assign o_axi_w_strb  = axi_req.w.strb;
assign o_axi_w_last  = axi_req.w.last;

assign o_axi_b_ready = axi_req.b_ready;

assign o_axi_ar_valid = axi_req.ar_valid;
assign o_axi_ar_addr  = axi_req.ar.addr;
assign o_axi_ar_len   = axi_req.ar.len;
assign o_axi_ar_size  = axi_req.ar.size;
assign o_axi_ar_burst = axi_req.ar.burst;
assign o_axi_ar_id    = axi_req.ar.id;

assign o_axi_r_ready = axi_req.r_ready;

always_comb begin
    axi_rsp          = '0;
    axi_rsp.aw_ready = i_axi_aw_ready;
    axi_rsp.w_ready  = i_axi_w_ready;
    axi_rsp.b_valid  = i_axi_b_valid;
    axi_rsp.b.id     = i_axi_b_id;
    axi_rsp.b.resp   = i_axi_b_resp;
    axi_rsp.ar_ready = i_axi_ar_ready;
    axi_rsp.r_valid  = i_axi_r_valid;
    axi_rsp.r.id     = i_axi_r_id;
    axi_rsp.r.data   = i_axi_r_data;
    axi_rsp.r.resp   = i_axi_r_resp;
    axi_rsp.r.last   = i_axi_r_last;
end

endmodule

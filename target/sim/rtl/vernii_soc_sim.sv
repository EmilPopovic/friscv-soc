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
    input  logic clk_i,
    input  logic rst_ni,

    output logic end_o,

    input  logic uart0_rx_i,
    output logic uart0_tx_o,

    input  logic jtag_tck_i,
    input  logic jtag_tms_i,
    input  logic jtag_trst_ni,
    input  logic jtag_tdi_i,
    output logic jtag_tdo_o,
    output logic jtag_tdo_oe_o,

    input  logic [NumStraps-1:0] strap_i,

    input  logic [31:0] gpio_a_i,
    output logic [31:0] gpio_a_o,
    output logic [31:0] gpio_a_oe_o,

    output logic       qspi0_sck_o,
    output logic       qspi0_sck_oe_o,
    output logic [2:0] qspi0_cs_o,
    output logic [2:0] qspi0_cs_oe_o,
    output logic [3:0] qspi0_sd_o,
    output logic [3:0] qspi0_sd_oe_o,
    input  logic [3:0] qspi0_sd_i,

    output logic        axi_aw_valid_o,
    input  logic        axi_aw_ready_i,
    output logic [31:0] axi_aw_addr_o,
    output logic [7:0]  axi_aw_len_o,
    output logic [2:0]  axi_aw_size_o,
    output logic [1:0]  axi_aw_burst_o,
    output logic        axi_aw_id_o,

    output logic        axi_w_valid_o,
    input  logic        axi_w_ready_i,
    output logic [31:0] axi_w_data_o,
    output logic [3:0]  axi_w_strb_o,
    output logic        axi_w_last_o,

    input  logic        axi_b_valid_i,
    output logic        axi_b_ready_o,
    input  logic [1:0]  axi_b_resp_i,
    input  logic        axi_b_id_i,

    output logic        axi_ar_valid_o,
    input  logic        axi_ar_ready_i,
    output logic [31:0] axi_ar_addr_o,
    output logic [7:0]  axi_ar_len_o,
    output logic [2:0]  axi_ar_size_o,
    output logic [1:0]  axi_ar_burst_o,
    output logic        axi_ar_id_o,

    input  logic        axi_r_valid_i,
    output logic        axi_r_ready_o,
    input  logic [31:0] axi_r_data_i,
    input  logic [1:0]  axi_r_resp_i,
    input  logic        axi_r_last_i,
    input  logic        axi_r_id_i
);

localparam int unsigned PinmuxSlv    = 0;
localparam int unsigned HyperCfgSlv  = 1;
localparam int unsigned NumMRegRules = 2;

localparam axi_pkg::xbar_rule_32_t [NumMRegRules-1:0] MRegRules = '{
    '{ idx: HyperCfgSlv, start_addr: 32'h0401_0000, end_addr: 32'h0401_1000 },
    '{ idx: PinmuxSlv,   start_addr: 32'h0400_0000, end_addr: 32'h0400_1000 }
};

vernii_axi_req_t  axi_req;
vernii_axi_resp_t axi_rsp;

`pragma diagnostic push
`pragma diagnostic ignore="-Wunused-but-set-variable"
vernii_reg_req_t [NumMRegRules-1:0] m_reg_req;
vernii_reg_rsp_t [NumMRegRules-1:0] m_reg_rsp;
`pragma diagnostic pop

for (genvar i = 0; i < NumMRegRules; i++) begin : gen_m_reg_sink
    assign m_reg_rsp[i].rdata = '0;
    assign m_reg_rsp[i].error = 1'b0;
    assign m_reg_rsp[i].ready = 1'b1;
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
    .NumMRegRules     ( NumMRegRules     ),
    .MRegRules        ( MRegRules        ),
    .HaltOnEnd        ( 1                )
) i_vernii_soc (
    .clk_i,
    .rst_ni,
    .end_o,
    .test_mode_i    ( 1'b0          ),
    .por_rst_no     (               ),
    .soc_rst_no     (               ),
    .s_axi_gp_req_i ( '0            ),
    .s_axi_gp_rsp_o (               ),
    .m_axi_hp_req_o ( axi_req       ),
    .m_axi_hp_rsp_i ( axi_rsp       ),
    .m_reg_req_o    ( m_reg_req     ),
    .m_reg_rsp_i    ( m_reg_rsp     ),
    .ext_irq_i      ( '0            ),
    .strap_i,
    .uart0_rx_i,
    .uart0_tx_o,
    .jtag_tck_i,
    .jtag_tms_i,
    .jtag_trst_ni,
    .jtag_tdi_i,
    .jtag_tdo_o,
    .jtag_tdo_oe_o,
    .qspi0_sck_o,
    .qspi0_sck_oe_o,
    .qspi0_cs_o,
    .qspi0_cs_oe_o,
    .qspi0_sd_o,
    .qspi0_sd_oe_o,
    .qspi0_sd_i,
    .gpio_a_i,
    .gpio_a_o,
    .gpio_a_oe_o
);
`pragma diagnostic pop

assign axi_aw_valid_o = axi_req.aw_valid;
assign axi_aw_addr_o  = axi_req.aw.addr;
assign axi_aw_len_o   = axi_req.aw.len;
assign axi_aw_size_o  = axi_req.aw.size;
assign axi_aw_burst_o = axi_req.aw.burst;
assign axi_aw_id_o    = axi_req.aw.id;

assign axi_w_valid_o = axi_req.w_valid;
assign axi_w_data_o  = axi_req.w.data;
assign axi_w_strb_o  = axi_req.w.strb;
assign axi_w_last_o  = axi_req.w.last;

assign axi_b_ready_o = axi_req.b_ready;

assign axi_ar_valid_o = axi_req.ar_valid;
assign axi_ar_addr_o  = axi_req.ar.addr;
assign axi_ar_len_o   = axi_req.ar.len;
assign axi_ar_size_o  = axi_req.ar.size;
assign axi_ar_burst_o = axi_req.ar.burst;
assign axi_ar_id_o    = axi_req.ar.id;

assign axi_r_ready_o = axi_req.r_ready;

always_comb begin
    axi_rsp          = '0;
    axi_rsp.aw_ready = axi_aw_ready_i;
    axi_rsp.w_ready  = axi_w_ready_i;
    axi_rsp.b_valid  = axi_b_valid_i;
    axi_rsp.b.id     = axi_b_id_i;
    axi_rsp.b.resp   = axi_b_resp_i;
    axi_rsp.ar_ready = axi_ar_ready_i;
    axi_rsp.r_valid  = axi_r_valid_i;
    axi_rsp.r.id     = axi_r_id_i;
    axi_rsp.r.data   = axi_r_data_i;
    axi_rsp.r.resp   = axi_r_resp_i;
    axi_rsp.r.last   = axi_r_last_i;
end

endmodule

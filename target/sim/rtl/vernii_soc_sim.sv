// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

`timescale 1ns/1ps

module vernii_soc_sim import vernii_pkg::*; #(
    parameter int unsigned SramBase         = 32'h0000_0000,
    parameter int unsigned SramSize         = 32'h0000_2000,
    parameter int unsigned MemBase          = 32'h8000_0000,
    parameter int unsigned MemSize          = 32'h0100_0000,
    parameter int unsigned LineBytes        = 32,
    parameter int unsigned Ways             = 4,
    parameter bit          SramTags         = 1'b1,
    parameter int unsigned ZsblRomSizeBytes = friscv_zsbl_rom_pkg::ZSBL_PROG_BYTES,
    parameter int unsigned NumStraps        = 13
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

vernii_reg_req_t [NumExtRegSlv-1:0] reg_ext_req;
vernii_reg_rsp_t [NumExtRegSlv-1:0] reg_ext_rsp;

for (genvar i = 0; i < NumExtRegSlv; i++) begin : gen_reg_ext_sink
    assign reg_ext_rsp[i].rdata = '0;
    assign reg_ext_rsp[i].error = 1'b0;
    assign reg_ext_rsp[i].ready = 1'b1;
end

vernii_soc #(
    .SramBase         ( SramBase         ),
    .SramSize         ( SramSize         ),
    .MemBase          ( MemBase          ),
    .MemSize          ( MemSize          ),
    .LineBytes        ( LineBytes        ),
    .Ways             ( Ways             ),
    .SramTags         ( SramTags         ),
    .ZsblRomSizeBytes ( ZsblRomSizeBytes ),
    .NumStraps        ( NumStraps        ),
    .NumExtRegSlv     ( NumExtRegSlv     ),
    .ExtRegSlvRules   ( ExtRegSlvRules   ),
    .HaltOnEnd        ( 1                )
) i_vernii_soc (
    .i_clk         ( i_clk         ),
    .i_rstn        ( i_rstn        ),
    .o_por_rstn    (               ),
    .o_soc_rstn    (               ),
    .o_end         ( o_end         ),
    .o_axi_mem_req ( axi_req       ),
    .i_axi_mem_rsp ( axi_rsp       ),
    .o_reg_ext_req ( reg_ext_req   ),
    .i_reg_ext_rsp ( reg_ext_rsp   ),
    .i_strap       ( i_strap       ),
    .i_uart_rx     ( i_uart_rx     ),
    .o_uart_tx     ( o_uart_tx     ),
    .i_jtag_tck    ( i_jtag_tck    ),
    .i_jtag_tms    ( i_jtag_tms    ),
    .i_jtag_trstn  ( i_jtag_trstn  ),
    .i_jtag_tdi    ( i_jtag_tdi    ),
    .o_jtag_tdo    ( o_jtag_tdo    ),
    .o_jtag_tdo_oe ( o_jtag_tdo_oe ),
    .o_qspi_sck    ( o_qspi_sck    ),
    .o_qspi_sck_oe ( o_qspi_sck_oe ),
    .o_qspi_cs     ( o_qspi_cs     ),
    .o_qspi_cs_oe  ( o_qspi_cs_oe  ),
    .o_qspi_sd     ( o_qspi_sd     ),
    .o_qspi_sd_oe  ( o_qspi_sd_oe  ),
    .i_qspi_sd     ( i_qspi_sd     ),
    .i_ext_irq     ( '0            ),
    .i_gpio        ( i_gpio        ),
    .o_gpio        ( o_gpio        ),
    .o_gpio_oe     ( o_gpio_oe     )
);

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

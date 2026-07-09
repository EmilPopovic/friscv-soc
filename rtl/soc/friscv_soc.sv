// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

`include "axi/typedef.svh"
`include "axi/assign.svh"
`include "register_interface/typedef.svh"
`include "apb/typedef.svh"

`timescale 1ns/1ps

module friscv_soc (
    input  logic  i_clk,
    input  logic  i_rstn,

    output logic  o_end,

    // UART
    input  logic  i_uart_rx,
    output logic  o_uart_tx
);

// ============================================================
// Parameters
// ============================================================

localparam int unsigned AxiAddrWidth = 32;
localparam int unsigned AxiDataWidth = 32;
localparam int unsigned AxiIdWidth   = 1;
localparam int unsigned AxiUserWidth = 1;

// Crossbar port map
//  Slave  port 0: CPU
//  Master port 0: RAM
//  Master port 1: Peripherals (UART, etc.)
localparam int unsigned NumMst   = 2;
localparam int unsigned RamPort  = 0;
localparam int unsigned UartPort = 1;

localparam axi_pkg::xbar_cfg_t XbarCfg = '{
    NoSlvPorts:         1,
    NoMstPorts:         NumMst,
    MaxMstTrans:        4,
    MaxSlvTrans:        4,
    FallThrough:        1'b0,
    LatencyMode:        axi_pkg::CUT_ALL_AX,
    AxiIdWidthSlvPorts: AxiIdWidth,
    AxiIdUsedSlvPorts:  AxiIdWidth,
    UniqueIds:          1'b0,
    AxiAddrWidth:       AxiAddrWidth,
    AxiDataWidth:       AxiDataWidth,
    NoAddrRules:        NumMst
};

// Address decode
// idx is the target master-port index
// Order of rules does not matter.
localparam axi_pkg::xbar_rule_32_t [NumMst-1:0] AddrMap = '{
    '{ idx: UartPort, start_addr: 32'h1000_0000, end_addr: 32'h1000_1000 },
    '{ idx: RamPort,  start_addr: 32'h8000_0000, end_addr: 32'h8100_0000 }
};

// ============================================================
// CPU subsystem
// ============================================================

friscv_mem_if mem_if();

friscv_cpu_subsystem_core cpu_subsystem (
    .i_clk   ( i_clk  ),
    .i_rstn  ( i_rstn ),
    .o_end   ( o_end  ),
    .i_msip  ( 1'b0   ),
    .i_mtip  ( 1'b0   ),
    .i_meip  ( 1'b0   ),
    .i_mtime ( 64'd0  ),
    .mem_if  ( mem_if )
);

// ============================================================
// mem_if -> flat AXI4 adapter
// ============================================================

// AW channel
logic        m_axi_awvalid;
logic        m_axi_awready;
logic [31:0] m_axi_awaddr;
logic [2:0]  m_axi_awsize;
logic [3:0]  m_axi_awcache;
logic [2:0]  m_axi_awprot;
logic [1:0]  m_axi_awburst;
logic [7:0]  m_axi_awlen;
logic        m_axi_awlock;
logic [3:0]  m_axi_awqos;
// W channel
logic        m_axi_wvalid;
logic        m_axi_wready;
logic        m_axi_wlast;
logic [31:0] m_axi_wdata;
logic [3:0]  m_axi_wstrb;
// B channel
logic        m_axi_bvalid;
logic        m_axi_bready;
logic [1:0]  m_axi_bresp;
// AR channel
logic        m_axi_arvalid;
logic        m_axi_arready;
logic [31:0] m_axi_araddr;
logic [2:0]  m_axi_arsize;
logic [3:0]  m_axi_arcache;
logic [2:0]  m_axi_arprot;
logic [1:0]  m_axi_arburst;
logic [7:0]  m_axi_arlen;
logic        m_axi_arlock;
logic [3:0]  m_axi_arqos;
// R channel
logic        m_axi_rvalid;
logic        m_axi_rready;
logic        m_axi_rlast;
logic [31:0] m_axi_rdata;
logic [1:0]  m_axi_rresp;

friscv_axi4_full_adapter m_axi (
    .i_clk          ( i_clk         ),
    .i_rstn         ( i_rstn        ),
    .mem_if         ( mem_if        ),
    .m_axi_awvalid  ( m_axi_awvalid ),
    .m_axi_awready  ( m_axi_awready ),
    .m_axi_awaddr   ( m_axi_awaddr  ),
    .m_axi_awsize   ( m_axi_awsize  ),
    .m_axi_awcache  ( m_axi_awcache ),
    .m_axi_awprot   ( m_axi_awprot  ),
    .m_axi_awburst  ( m_axi_awburst ),
    .m_axi_awlen    ( m_axi_awlen   ),
    .m_axi_awlock   ( m_axi_awlock  ),
    .m_axi_awqos    ( m_axi_awqos   ),
    .m_axi_wvalid   ( m_axi_wvalid  ),
    .m_axi_wready   ( m_axi_wready  ),
    .m_axi_wlast    ( m_axi_wlast   ),
    .m_axi_wdata    ( m_axi_wdata   ),
    .m_axi_wstrb    ( m_axi_wstrb   ),
    .m_axi_bvalid   ( m_axi_bvalid  ),
    .m_axi_bready   ( m_axi_bready  ),
    .m_axi_bresp    ( m_axi_bresp   ),
    .m_axi_arvalid  ( m_axi_arvalid ),
    .m_axi_arready  ( m_axi_arready ),
    .m_axi_araddr   ( m_axi_araddr  ),
    .m_axi_arsize   ( m_axi_arsize  ),
    .m_axi_arcache  ( m_axi_arcache ),
    .m_axi_arprot   ( m_axi_arprot  ),
    .m_axi_arburst  ( m_axi_arburst ),
    .m_axi_arlen    ( m_axi_arlen   ),
    .m_axi_arlock   ( m_axi_arlock  ),
    .m_axi_arqos    ( m_axi_arqos   ),
    .m_axi_rvalid   ( m_axi_rvalid  ),
    .m_axi_rready   ( m_axi_rready  ),
    .m_axi_rlast    ( m_axi_rlast   ),
    .m_axi_rdata    ( m_axi_rdata   ),
    .m_axi_rresp    ( m_axi_rresp   )
);

// ============================================================
// Interconnect: flat AXI -> AXI_BUS -> axi_xbar -> {RAM, peripherals}
// ============================================================

AXI_BUS #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
) xbar_slv [0:0] ();

AXI_BUS #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
) xbar_mst [NumMst-1:0] ();

// Bundle the flat adapter wires into the xbar's slave port
// Signals the CPU does not produce (id/region/atop/user) are tied to 0
// AW
assign xbar_slv[0].aw_id     = '0;
assign xbar_slv[0].aw_addr   = m_axi_awaddr;
assign xbar_slv[0].aw_len    = m_axi_awlen;
assign xbar_slv[0].aw_size   = m_axi_awsize;
assign xbar_slv[0].aw_burst  = m_axi_awburst;
assign xbar_slv[0].aw_lock   = m_axi_awlock;
assign xbar_slv[0].aw_cache  = m_axi_awcache;
assign xbar_slv[0].aw_prot   = m_axi_awprot;
assign xbar_slv[0].aw_qos    = m_axi_awqos;
assign xbar_slv[0].aw_region = '0;
assign xbar_slv[0].aw_atop   = '0;
assign xbar_slv[0].aw_user   = '0;
assign xbar_slv[0].aw_valid  = m_axi_awvalid;
assign m_axi_awready         = xbar_slv[0].aw_ready;  // Master of cpu is Slave 0 of xbar
// W
assign xbar_slv[0].w_data    = m_axi_wdata;
assign xbar_slv[0].w_strb    = m_axi_wstrb;
assign xbar_slv[0].w_last    = m_axi_wlast;
assign xbar_slv[0].w_user    = '0;
assign xbar_slv[0].w_valid   = m_axi_wvalid;
assign m_axi_wready          = xbar_slv[0].w_ready;
// B
assign m_axi_bresp           = xbar_slv[0].b_resp;
assign m_axi_bvalid          = xbar_slv[0].b_valid;
assign xbar_slv[0].b_ready   = m_axi_bready;
// AR
assign xbar_slv[0].ar_id     = '0;
assign xbar_slv[0].ar_addr   = m_axi_araddr;
assign xbar_slv[0].ar_len    = m_axi_arlen;
assign xbar_slv[0].ar_size   = m_axi_arsize;
assign xbar_slv[0].ar_burst  = m_axi_arburst;
assign xbar_slv[0].ar_lock   = m_axi_arlock;
assign xbar_slv[0].ar_cache  = m_axi_arcache;
assign xbar_slv[0].ar_prot   = m_axi_arprot;
assign xbar_slv[0].ar_qos    = m_axi_arqos;
assign xbar_slv[0].ar_region = '0;
assign xbar_slv[0].ar_user   = '0;
assign xbar_slv[0].ar_valid  = m_axi_arvalid;
assign m_axi_arready         = xbar_slv[0].ar_ready;
// R
assign m_axi_rdata           = xbar_slv[0].r_data;
assign m_axi_rresp           = xbar_slv[0].r_resp;
assign m_axi_rlast           = xbar_slv[0].r_last;
assign m_axi_rvalid          = xbar_slv[0].r_valid;
assign xbar_slv[0].r_ready   = m_axi_rready;

axi_xbar_intf #(
    .AXI_USER_WIDTH ( AxiUserWidth            ),
    .Cfg            ( XbarCfg                 ),
    .rule_t         ( axi_pkg::xbar_rule_32_t )
) xbar (
    .clk_i                 ( i_clk    ),
    .rst_ni                ( i_rstn   ),
    .test_i                ( 1'b0     ),
    .slv_ports             ( xbar_slv ),
    .mst_ports             ( xbar_mst ),
    .addr_map_i            ( AddrMap  ),
    .en_default_mst_port_i ( '0       ),
    .default_mst_port_i    ( '0       )
);

// ============================================================
// RAM: xbar master port -> axi_to_mem -> tc_sram
// ============================================================

logic        mem_req, mem_gnt, mem_we, mem_rvalid;
logic [31:0] mem_addr, mem_wdata, mem_rdata;
logic [3:0]  mem_be;

axi_to_mem_intf #(
    .ADDR_WIDTH ( AxiAddrWidth ),
    .DATA_WIDTH ( AxiDataWidth ),
    .ID_WIDTH   ( AxiIdWidth   ),
    .USER_WIDTH ( AxiUserWidth ),
    .NUM_BANKS  ( 1            )
) axi_to_mem (
    .clk_i        ( i_clk             ),
    .rst_ni       ( i_rstn            ),
    .busy_o       (                   ),
    .slv          ( xbar_mst[RamPort] ),
    .mem_req_o    ( mem_req           ),
    .mem_gnt_i    ( mem_gnt           ),
    .mem_addr_o   ( mem_addr          ),
    .mem_wdata_o  ( mem_wdata         ),
    .mem_strb_o   ( mem_be            ),
    .mem_atop_o   (                   ),
    .mem_we_o     ( mem_we            ),
    .mem_rvalid_i ( mem_rvalid        ),
    .mem_rdata_i  ( mem_rdata         )
);

tc_sram #(
    .NumWords  ( 16384 ),
    .DataWidth ( 32    ),
    .ByteWidth ( 8     ),
    .NumPorts  ( 1     ),
    .Latency   ( 1     )
) sram (
    .clk_i   ( i_clk          ),
    .rst_ni  ( i_rstn         ),
    .req_i   ( mem_req        ),
    .we_i    ( mem_we         ),
    .addr_i  ( mem_addr[15:2] ),
    .wdata_i ( mem_wdata      ),
    .be_i    ( mem_be         ),
    .rdata_o ( mem_rdata      )
);

assign mem_gnt = 1'b1;
always_ff @(posedge i_clk) begin
    if (!i_rstn) mem_rvalid <= 1'b0;
    else         mem_rvalid <= mem_req & !mem_we;
end

// ============================================================
// Peripherals: xbar port -> AXI-Lite -> reg_bus -> APB -> UART
// ============================================================

AXI_LITE #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth )
) periph_lite ();

axi_to_axi_lite_intf #(
    .AXI_ADDR_WIDTH     ( AxiAddrWidth ),
    .AXI_DATA_WIDTH     ( AxiDataWidth ),
    .AXI_ID_WIDTH       ( AxiIdWidth   ),
    .AXI_USER_WIDTH     ( AxiUserWidth ),
    .AXI_MAX_WRITE_TXNS ( 1            ),
    .AXI_MAX_READ_TXNS  ( 1            ),
    .FALL_THROUGH       ( 1'b1         )
) axi_to_lite (
    .clk_i      ( i_clk              ),
    .rst_ni     ( i_rstn             ),
    .testmode_i ( 1'b0               ),
    .slv        ( xbar_mst[UartPort] ),
    .mst        ( periph_lite        )
);

// Struct types for the reg/apb
typedef logic [AxiAddrWidth-1:0]   addr_t;
typedef logic [AxiDataWidth-1:0]   data_t;
typedef logic [AxiDataWidth/8-1:0] strb_t;
`AXI_LITE_TYPEDEF_ALL(axi_lite, addr_t, data_t, strb_t)  // axi_lite_req_t, axi_lite_resp_t
`REG_BUS_TYPEDEF_ALL (reg_bus,  addr_t, data_t, strb_t)  // reg_bus_req_t, reg_bus_rsp_t
`APB_TYPEDEF_ALL     (apb,      addr_t, data_t, strb_t)  // apb_req_t, apb_resp_t

// Connect the AXI_LITE interface object and req/rsp structs
axi_lite_req_t  lite_req;
axi_lite_resp_t lite_rsp;
`AXI_LITE_ASSIGN_TO_REQ   (lite_req, periph_lite)
`AXI_LITE_ASSIGN_FROM_RESP(periph_lite, lite_rsp)

// AXI-Lite -> reg_bus
reg_bus_req_t reg_req;
reg_bus_rsp_t reg_rsp;
axi_lite_to_reg #(
    .ADDR_WIDTH     ( AxiAddrWidth    ),
    .DATA_WIDTH     ( AxiDataWidth    ),
    .axi_lite_req_t ( axi_lite_req_t  ),
    .axi_lite_rsp_t ( axi_lite_resp_t ),
    .reg_req_t      ( reg_bus_req_t   ),
    .reg_rsp_t      ( reg_bus_rsp_t   )
) lite_to_reg (
    .clk_i          ( i_clk    ),
    .rst_ni         ( i_rstn   ),
    .axi_lite_req_i ( lite_req ),
    .axi_lite_rsp_o ( lite_rsp ),
    .reg_req_o      ( reg_req  ),
    .reg_rsp_i      ( reg_rsp  )
);

// reg_bus -> APB
apb_req_t  apb_req;
apb_resp_t apb_rsp;
reg_to_apb #(
    .reg_req_t ( reg_bus_req_t ),
    .reg_rsp_t ( reg_bus_rsp_t ),
    .apb_req_t ( apb_req_t     ),
    .apb_rsp_t ( apb_resp_t    )
) reg_to_apb (
    .clk_i     ( i_clk   ),
    .rst_ni    ( i_rstn  ),
    .reg_req_i ( reg_req ),
    .reg_rsp_o ( reg_rsp ),
    .apb_req_o ( apb_req ),
    .apb_rsp_i ( apb_rsp )
);

// APB -> 16550 UART
apb_uart_wrap #(
    .apb_req_t ( apb_req_t  ),
    .apb_rsp_t ( apb_resp_t )
) uart (
    .clk_i     ( i_clk     ),
    .rst_ni    ( i_rstn    ),
    .apb_req_i ( apb_req   ),
    .apb_rsp_o ( apb_rsp   ),
    .intr_o    (           ),
    .sin_i     ( i_uart_rx ),
    .sout_o    ( o_uart_tx ),
    .cts_ni    ( 1'b0      ),
    .dsr_ni    ( 1'b0      ),
    .dcd_ni    ( 1'b0      ),
    .rin_ni    ( 1'b0      ),
    .out1_no   (           ),
    .out2_no   (           ),
    .rts_no    (           ),
    .dtr_no    (           )
);

endmodule

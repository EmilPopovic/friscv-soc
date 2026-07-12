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
    output logic  o_uart_tx,

    // JTAG
    input  logic  i_jtag_tck,
    input  logic  i_jtag_tms,
    input  logic  i_jtag_tdi,
    output logic  o_jtag_tdo
);

// ============================================================
// CPU subsystem
// ============================================================

friscv_mem_if mem_if();

logic [63:0] mtime;
logic        msip, mtip, meip;
assign meip = 1'b0;

// Debug module base address
localparam logic [31:0] DmBaseAddr = 32'h0001_0000;
localparam logic [31:0] DmSize     = 32'h0000_1000;

logic ndmreset;   // non-debug-module reset request from the DM
logic debug_req;  // async debug request to the hart

// System reset asserted by the power-on reset or by the debugger's ndmreset.
// Everything except the debug module (dm_top) and the JTAG DTM (dmi_jtag) runs
// on this reset, so an ndmreset resets the whole SoC while debug stays alive.
logic soc_rstn;
assign soc_rstn = i_rstn & ~ndmreset;

friscv_cpu_subsystem_core #(
    .RAM_BASE            ( 32'h8000_0000 ),
    .ZSBL_ROM_SIZE_BYTES ( 64            ),
    .ZSBL_BASE           ( 32'h20000     ),
    .DM_BASE             ( DmBaseAddr    )
) cpu_subsystem (
    .i_clk     ( i_clk     ),
    .i_rstn    ( soc_rstn  ),
    .o_end     ( o_end     ),
    .i_msip    ( msip      ),
    .i_mtip    ( mtip      ),
    .i_meip    ( meip      ),
    .i_mtime   ( mtime     ),
    .mem_if    ( mem_if    ),
    .i_dbg_req ( debug_req )
);

// ============================================================
// mem_if -> flat AXI-Lite adapter
// ============================================================

// AW channel
logic        m_axi_awvalid;
logic        m_axi_awready;
logic [31:0] m_axi_awaddr;
logic [2:0]  m_axi_awprot;
// W channel
logic        m_axi_wvalid;
logic        m_axi_wready;
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
logic [2:0]  m_axi_arprot;
// R channel
logic        m_axi_rvalid;
logic        m_axi_rready;
logic [31:0] m_axi_rdata;
logic [1:0]  m_axi_rresp;

friscv_axi_lite_adapter m_axi (
    .i_clk          ( i_clk         ),
    .i_rstn         ( soc_rstn      ),
    .mem_if         ( mem_if        ),
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

// ============================================================
// Interconnect: flat AXI-Lite -> AXI_LITE -> lite xbar -> {RAM, peripherals}
// ============================================================

localparam int unsigned AxiAddrWidth = 32;
localparam int unsigned AxiDataWidth = 32;
localparam int unsigned AxiIdWidth   = 1;
localparam int unsigned AxiUserWidth = 1;

// Lite crossbar port map:
//  Slave  port 0: CPU
//  Slave  port 1: Debug module System Bus Access (SBA) master
//  ---------------------
//  Master port 0: CLINT
//  Master port 1: Peripheral regs (DM, UART0, scratch)
//  Master port 2: RAM
localparam int unsigned NumAxiLiteSlv   = 2;
localparam int unsigned CpuPort         = 0;
localparam int unsigned DmSbaPort       = 1;

localparam int unsigned NumAxiLiteMst   = 3;
localparam int unsigned NumAxiLiteRules = 5;
localparam int unsigned ClintPort       = 0;
localparam int unsigned RegsPort        = 1;
localparam int unsigned SramPort        = 2;

localparam int unsigned SramBase    = 32'h0000_0000;  // Sram starts at 0
localparam int unsigned SramSize    = 32'h0000_4000;  // 16 KiB RAM

localparam axi_pkg::xbar_cfg_t AxiLiteXbarCfg = '{
    NoSlvPorts:         NumAxiLiteSlv,
    NoMstPorts:         NumAxiLiteMst,
    MaxMstTrans:        4,
    MaxSlvTrans:        4,
    FallThrough:        1'b0,
    LatencyMode:        axi_pkg::NO_LATENCY,
    AxiIdWidthSlvPorts: 0,
    AxiIdUsedSlvPorts:  0,
    UniqueIds:          1'b0,
    AxiAddrWidth:       AxiAddrWidth,
    AxiDataWidth:       AxiDataWidth,
    NoAddrRules:        NumAxiLiteRules
};

// Address decode
// idx is the target master-port index
// Order of rules does not matter.
localparam axi_pkg::xbar_rule_32_t [NumAxiLiteRules-1:0] AxiLiteAddrMap = '{
    '{ idx: ClintPort, start_addr: 32'h0200_0000, end_addr: 32'h0201_0000 },        // CLINT
    '{ idx: RegsPort,  start_addr: 32'h1000_0000, end_addr: 32'h1000_1000 },        // UART0
    '{ idx: RegsPort,  start_addr: DmBaseAddr,    end_addr: DmBaseAddr + DmSize },  // Debug module
    '{ idx: RegsPort,  start_addr: 32'h4000_0000, end_addr: 32'h4000_1000 },        // Scratch
    '{ idx: SramPort,  start_addr: SramBase,      end_addr: SramBase + SramSize }   // SRAM
};

// Struct types for the reg/apb
typedef logic [AxiAddrWidth-1:0]   addr_t;
typedef logic [AxiDataWidth-1:0]   data_t;
typedef logic [AxiDataWidth/8-1:0] strb_t;
`AXI_LITE_TYPEDEF_ALL(axi_lite, addr_t, data_t, strb_t)  // axi_lite_req_t, axi_lite_resp_t
`REG_BUS_TYPEDEF_ALL (reg_bus,  addr_t, data_t, strb_t)  // reg_bus_req_t, reg_bus_rsp_t
`APB_TYPEDEF_ALL     (apb,      addr_t, data_t, strb_t)  // apb_req_t, apb_resp_t

// Masters -> AXI-Lite xbar Slave ports
AXI_LITE #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth )
) axi_lite_xbar_slv[NumAxiLiteSlv-1:0] ();

// AXI-Lite xbar Master -> peripheral Slaves
AXI_LITE #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth )
) axi_lite_xbar_mst[NumAxiLiteMst-1:0] ();

// Bundle the flat adapter wires into the lite xbar's CPU slave port
// AW
assign axi_lite_xbar_slv[CpuPort].aw_addr  = m_axi_awaddr;
assign axi_lite_xbar_slv[CpuPort].aw_prot  = m_axi_awprot;
assign axi_lite_xbar_slv[CpuPort].aw_valid = m_axi_awvalid;
assign m_axi_awready                       = axi_lite_xbar_slv[CpuPort].aw_ready;
// W
assign axi_lite_xbar_slv[CpuPort].w_data   = m_axi_wdata;
assign axi_lite_xbar_slv[CpuPort].w_strb   = m_axi_wstrb;
assign axi_lite_xbar_slv[CpuPort].w_valid  = m_axi_wvalid;
assign m_axi_wready                        = axi_lite_xbar_slv[CpuPort].w_ready;
// B
assign m_axi_bresp                         = axi_lite_xbar_slv[CpuPort].b_resp;
assign m_axi_bvalid                        = axi_lite_xbar_slv[CpuPort].b_valid;
assign axi_lite_xbar_slv[CpuPort].b_ready  = m_axi_bready;
// AR
assign axi_lite_xbar_slv[CpuPort].ar_addr  = m_axi_araddr;
assign axi_lite_xbar_slv[CpuPort].ar_prot  = m_axi_arprot;
assign axi_lite_xbar_slv[CpuPort].ar_valid = m_axi_arvalid;
assign m_axi_arready                       = axi_lite_xbar_slv[CpuPort].ar_ready;
// R
assign m_axi_rdata                         = axi_lite_xbar_slv[CpuPort].r_data;
assign m_axi_rresp                         = axi_lite_xbar_slv[CpuPort].r_resp;
assign m_axi_rvalid                        = axi_lite_xbar_slv[CpuPort].r_valid;
assign axi_lite_xbar_slv[CpuPort].r_ready  = m_axi_rready;

// The AXI-Lite xbar
axi_lite_xbar_intf #(
    .Cfg    ( AxiLiteXbarCfg          ),
    .rule_t ( axi_pkg::xbar_rule_32_t )
) axi_lite_xbar (
    .clk_i                 ( i_clk             ),
    .rst_ni                ( soc_rstn          ),
    .test_i                ( 1'b0              ),
    .slv_ports             ( axi_lite_xbar_slv ),
    .mst_ports             ( axi_lite_xbar_mst ),
    .addr_map_i            ( AxiLiteAddrMap    ),
    .en_default_mst_port_i ( '0                ),
    .default_mst_port_i    ( '0                )
);

// ============================================================
// Reg demux from Lite xbar
// ============================================================

axi_lite_req_t  regs_lite_req;
axi_lite_resp_t regs_lite_rsp;
`AXI_LITE_ASSIGN_TO_REQ   (regs_lite_req, axi_lite_xbar_mst[RegsPort])
`AXI_LITE_ASSIGN_FROM_RESP(axi_lite_xbar_mst[RegsPort], regs_lite_rsp)

// AXI-Lite -> reg_bus
reg_bus_req_t regs_reg_req;
reg_bus_rsp_t regs_reg_rsp;
axi_lite_to_reg #(
    .ADDR_WIDTH     ( AxiAddrWidth    ),
    .DATA_WIDTH     ( AxiDataWidth    ),
    .BUFFER_DEPTH   ( 1               ),
    .axi_lite_req_t ( axi_lite_req_t  ),
    .axi_lite_rsp_t ( axi_lite_resp_t ),
    .reg_req_t      ( reg_bus_req_t   ),
    .reg_rsp_t      ( reg_bus_rsp_t   )
) lite_to_reg (
    .clk_i          ( i_clk       ),
    .rst_ni         ( soc_rstn    ),
    .axi_lite_req_i ( regs_lite_req ),
    .axi_lite_rsp_o ( regs_lite_rsp ),
    .reg_req_o      ( regs_reg_req  ),
    .reg_rsp_i      ( regs_reg_rsp  )
);

localparam int unsigned NoRegPorts   = 3;
localparam int unsigned DmPort       = 0;
localparam int unsigned Uart0Port    = 1;
localparam int unsigned ScratchPort  = 2;

reg_bus_req_t [NoRegPorts-1:0] reg_dev_req;
reg_bus_rsp_t [NoRegPorts-1:0] reg_dev_rsp;

localparam int unsigned NoRegRules = 3;
localparam axi_pkg::xbar_rule_32_t [NoRegRules-1:0] RegAddrMap = '{
    '{ idx: DmPort,      start_addr: DmBaseAddr,    end_addr: DmBaseAddr + DmSize },
    '{ idx: Uart0Port,   start_addr: 32'h1000_0000, end_addr: 32'h1000_1000 },
    '{ idx: ScratchPort, start_addr: 32'h4000_0000, end_addr: 32'h4000_1000 }
};

logic [$clog2(NoRegPorts)-1:0] reg_select;
addr_decode #(
    .NoIndices ( NoRegPorts              ),
    .NoRules   ( NoRegRules              ),
    .addr_t    ( addr_t                  ),
    .rule_t    ( axi_pkg::xbar_rule_32_t )
) reg_decode (
    .addr_i           ( regs_reg_req.addr ),
    .addr_map_i       ( RegAddrMap        ),
    .idx_o            ( reg_select        ),
    .dec_valid_o      (                   ),
    .dec_error_o      (                   ),
    .en_default_idx_i ( 1'b1              ),
    .default_idx_i    ( 2'(DmPort)        )
);

reg_demux #(
    .NoPorts ( NoRegPorts    ),
    .req_t   ( reg_bus_req_t ),
    .rsp_t   ( reg_bus_rsp_t )
) reg_demux (
    .clk_i       ( i_clk        ),
    .rst_ni      ( soc_rstn     ),
    .in_select_i ( reg_select   ),
    .in_req_i    ( regs_reg_req ),
    .in_rsp_o    ( regs_reg_rsp ),
    .out_req_o   ( reg_dev_req  ),
    .out_rsp_i   ( reg_dev_rsp  )
);

// ============================================================
// Scratch register (32-bit reg aliased in its 4K window)
// ============================================================

logic [31:0] scratch_q;
always_ff @(posedge i_clk) begin
    if (!soc_rstn) begin
        scratch_q <= 32'h0;
    end else if (reg_dev_req[ScratchPort].valid && reg_dev_req[ScratchPort].write) begin
        for (int i = 0; i < 4; i++) begin
            if (reg_dev_req[ScratchPort].wstrb[i])
                scratch_q[8*i +: 8] <= reg_dev_req[ScratchPort].wdata[8*i +: 8];
        end
    end
end

assign reg_dev_rsp[ScratchPort].rdata = scratch_q;
assign reg_dev_rsp[ScratchPort].error = 1'b0;
assign reg_dev_rsp[ScratchPort].ready = 1'b1;

// ============================================================
// SRAM
// ============================================================

logic        sram_req, sram_gnt, sram_we, sram_rvalid;
logic [31:0] sram_addr, sram_wdata, sram_rdata;
logic [3:0]  sram_be;

// Lite xbar master port -> full AXI -> memory port
AXI_BUS #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
) sram_axi ();

axi_lite_to_axi_intf #(
    .AXI_DATA_WIDTH ( AxiDataWidth )
) sram_lite_to_axi (
    .in             ( axi_lite_xbar_mst[SramPort] ),
    .slv_aw_cache_i ( '0                          ),
    .slv_ar_cache_i ( '0                          ),
    .out            ( sram_axi                    )
);

axi_to_mem_intf #(
    .ADDR_WIDTH ( AxiAddrWidth ),
    .DATA_WIDTH ( AxiDataWidth ),
    .ID_WIDTH   ( AxiIdWidth   ),
    .USER_WIDTH ( AxiUserWidth ),
    .NUM_BANKS  ( 1            )
) axi_to_mem (
    .clk_i        ( i_clk                   ),
    .rst_ni       ( soc_rstn                ),
    .busy_o       (                         ),
    .slv          ( sram_axi                ),
    .mem_req_o    ( sram_req                ),
    .mem_gnt_i    ( sram_gnt                ),
    .mem_addr_o   ( sram_addr               ),
    .mem_wdata_o  ( sram_wdata              ),
    .mem_strb_o   ( sram_be                 ),
    .mem_atop_o   (                         ),
    .mem_we_o     ( sram_we                 ),
    .mem_rvalid_i ( sram_rvalid             ),
    .mem_rdata_i  ( sram_rdata              )
);

tc_sram #(
    .NumWords  ( SramSize/4 ),
    .DataWidth ( 32         ),
    .ByteWidth ( 8          ),
    .NumPorts  ( 1          ),
    .Latency   ( 1          )
) sram (
    .clk_i   ( i_clk                           ),
    .rst_ni  ( i_rstn                          ),
    .req_i   ( sram_req                        ),
    .we_i    ( sram_we                         ),
    .addr_i  ( sram_addr[$clog2(SramSize)-1:2] ),
    .wdata_i ( sram_wdata                      ),
    .be_i    ( sram_be                         ),
    .rdata_o ( sram_rdata                      )
);

assign sram_gnt = 1'b1;
always_ff @(posedge i_clk) begin
    if (!soc_rstn) sram_rvalid <= 1'b0;
    else           sram_rvalid <= sram_req;
end

// ============================================================
// Debugger
// ============================================================

// DMI (DTM <-> DM) channel
logic dmi_rst, dmi_req_valid, dmi_req_ready;
dm::dmi_req_t  dmi_req;

logic dmi_resp_valid, dmi_resp_ready;
dm::dmi_resp_t dmi_resp;

// 2 scratch regs, memory-mapped data regs at dm::DataAddr.
localparam dm::hartinfo_t HARTINFO = '{
    zero1:      '0,
    nscratch:   4'd2,
    zero0:      '0,
    dataaccess: 1'b1,
    datasize:   dm::DataCount,
    dataaddr:   dm::DataAddr
};

// DM slave (config / debug ROM) simple-memory port
logic        dbg_slv_req, dbg_slv_we, dbg_slv_gnt, dbg_slv_rvalid;
logic [31:0] dbg_slv_addr, dbg_slv_wdata, dbg_slv_rdata;
logic [3:0]  dbg_slv_be;

// DM System Bus Access (SBA) master port
logic        sba_req, sba_we, sba_gnt, sba_rvalid, sba_err, sba_other_err;
logic [31:0] sba_addr, sba_wdata, sba_rdata;
logic [3:0]  sba_be;

dm_top #(
    .NrHarts       ( 1          ),
    .BusWidth      ( 32         ),
    .DmBaseAddress ( DmBaseAddr )
) dm (
    // Keep the DM and DTM on the power-on reset so debug survives an ndmreset
    .clk_i                ( i_clk          ),
    .rst_ni               ( i_rstn         ),

    .next_dm_addr_i       ( '0             ),  // No next DM in the chain
    .testmode_i           ( 1'b0           ),
    .ndmreset_o           ( ndmreset       ),
    .ndmreset_ack_i       ( ndmreset       ),  // ack immediately
    .dmactive_o           (                ),
    .debug_req_o          ( debug_req      ),

    .unavailable_i        ( 1'b0           ),
    .hartinfo_i           ( HARTINFO       ),

    .slave_req_i          ( dbg_slv_req    ),
    .slave_we_i           ( dbg_slv_we     ),
    .slave_addr_i         ( dbg_slv_addr   ),
    .slave_be_i           ( dbg_slv_be     ),
    .slave_wdata_i        ( dbg_slv_wdata  ),
    .slave_rdata_o        ( dbg_slv_rdata  ),

    .master_req_o         ( sba_req        ),
    .master_add_o         ( sba_addr       ),
    .master_we_o          ( sba_we         ),
    .master_wdata_o       ( sba_wdata      ),
    .master_be_o          ( sba_be         ),
    .master_gnt_i         ( sba_gnt        ),
    .master_r_valid_i     ( sba_rvalid     ),
    .master_r_err_i       ( sba_err        ),
    .master_r_other_err_i ( sba_other_err  ),
    .master_r_rdata_i     ( sba_rdata      ),

    .dmi_rst_ni           ( dmi_rst        ),
    .dmi_req_valid_i      ( dmi_req_valid  ),
    .dmi_req_ready_o      ( dmi_req_ready  ),
    .dmi_req_i            ( dmi_req        ),

    .dmi_resp_valid_o     ( dmi_resp_valid ),
    .dmi_resp_ready_i     ( dmi_resp_ready ),
    .dmi_resp_o           ( dmi_resp       )
);

dmi_jtag #(
    .IdcodeValue ( 32'h00000DB3 )
) dmi (
    .clk_i            ( i_clk          ),
    .rst_ni           ( i_rstn         ),
    .testmode_i       ( 1'b0           ),

    .dmi_rst_no       ( dmi_rst        ),
    .dmi_req_o        ( dmi_req        ),
    .dmi_req_valid_o  ( dmi_req_valid  ),
    .dmi_req_ready_i  ( dmi_req_ready  ),

    .dmi_resp_i       ( dmi_resp       ),
    .dmi_resp_ready_o ( dmi_resp_ready ),
    .dmi_resp_valid_i ( dmi_resp_valid ),

    .tck_i            ( i_jtag_tck     ),
    .tms_i            ( i_jtag_tms     ),
    .trst_ni          ( 1'b1           ),
    .td_i             ( i_jtag_tdi     ),
    .td_o             ( o_jtag_tdo     ),
    .tdo_oe_o         (                )
);

reg_to_mem #(
    .AW    ( 32            ),
    .DW    ( 32            ),
    .req_t ( reg_bus_req_t ),
    .rsp_t ( reg_bus_rsp_t )
) dm_reg_to_mem (
    .clk_i     ( i_clk               ),
    .rst_ni    ( soc_rstn            ),
    .reg_req_i ( reg_dev_req[DmPort] ),
    .reg_rsp_o ( reg_dev_rsp[DmPort] ),
    .req_o     ( dbg_slv_req         ),
    .gnt_i     ( dbg_slv_gnt         ),
    .we_o      ( dbg_slv_we          ),
    .addr_o    ( dbg_slv_addr        ),
    .wdata_o   ( dbg_slv_wdata       ),
    .wstrb_o   ( dbg_slv_be          ),
    .rdata_i   ( dbg_slv_rdata       ),
    .rvalid_i  ( dbg_slv_rvalid      ),
    .rerror_i  ( 1'b0                )
);

assign dbg_slv_gnt = 1'b1;
always_ff @(posedge i_clk) begin
    if (!soc_rstn) dbg_slv_rvalid <= 1'b0;
    else           dbg_slv_rvalid <= dbg_slv_req & ~dbg_slv_we;
end

// DM SBA master port: dm master -> bridge -> lite xbar slave port
friscv_dm_sba_axi #(
    .AxiAddrWidth ( AxiAddrWidth ),
    .AxiDataWidth ( AxiDataWidth )
) dm_sba_axi (
    .i_clk          ( i_clk                        ),
    .i_rstn         ( soc_rstn                     ),
    .dm_req_i       ( sba_req                      ),
    .dm_addr_i      ( sba_addr                     ),
    .dm_we_i        ( sba_we                       ),
    .dm_wdata_i     ( sba_wdata                    ),
    .dm_be_i        ( sba_be                       ),
    .dm_gnt_o       ( sba_gnt                      ),
    .dm_rvalid_o    ( sba_rvalid                   ),
    .dm_err_o       ( sba_err                      ),
    .dm_other_err_o ( sba_other_err                ),
    .dm_rdata_o     ( sba_rdata                    ),
    .mst            ( axi_lite_xbar_slv[DmSbaPort] )
);

// ============================================================
// UART0: reg demux -> reg_bus -> APB -> UART0
// ============================================================

// reg_bus -> APB
apb_req_t  uart0_apb_req;
apb_resp_t uart0_apb_rsp;
reg_to_apb #(
    .reg_req_t ( reg_bus_req_t ),
    .reg_rsp_t ( reg_bus_rsp_t ),
    .apb_req_t ( apb_req_t     ),
    .apb_rsp_t ( apb_resp_t    )
) reg_to_apb (
    .clk_i     ( i_clk                  ),
    .rst_ni    ( soc_rstn               ),
    .reg_req_i ( reg_dev_req[Uart0Port] ),
    .reg_rsp_o ( reg_dev_rsp[Uart0Port] ),
    .apb_req_o ( uart0_apb_req          ),
    .apb_rsp_i ( uart0_apb_rsp          )
);

// APB -> 16550 UART
apb_uart_wrap #(
    .apb_req_t ( apb_req_t  ),
    .apb_rsp_t ( apb_resp_t )
) uart0 (
    .clk_i     ( i_clk         ),
    .rst_ni    ( soc_rstn      ),
    .apb_req_i ( uart0_apb_req ),
    .apb_rsp_o ( uart0_apb_rsp ),
    .intr_o    (               ),
    .sin_i     ( i_uart_rx     ),
    .sout_o    ( o_uart_tx     ),
    .cts_ni    ( 1'b0          ),
    .dsr_ni    ( 1'b0          ),
    .dcd_ni    ( 1'b0          ),
    .rin_ni    ( 1'b0          ),
    .out1_no   (               ),
    .out2_no   (               ),
    .rts_no    (               ),
    .dtr_no    (               )
);

// ============================================================
// CLINT: Lite xbar port -> AXI-Lite -> CLINT
// ============================================================

axi_lite_req_t  clint_lite_req;
axi_lite_resp_t clint_lite_rsp;
`AXI_LITE_ASSIGN_TO_REQ   (clint_lite_req, axi_lite_xbar_mst[ClintPort])
`AXI_LITE_ASSIGN_FROM_RESP(axi_lite_xbar_mst[ClintPort], clint_lite_rsp)

friscv_clint #(
    .CLK_FREQ_HZ   ( 50_000_000 ),
    .MTIME_FREQ_HZ ( 10_000_000 )
) clint (
    .clk_in        ( i_clk                   ),
    .rstn_in       ( soc_rstn                ),
    .time_out      ( mtime                   ),
    .msip_out      ( msip                    ),
    .mtip_out      ( mtip                    ),
    .s_axi_awaddr  ( clint_lite_req.aw.addr  ),
    .s_axi_awvalid ( clint_lite_req.aw_valid ),
    .s_axi_awready ( clint_lite_rsp.aw_ready ),
    .s_axi_wdata   ( clint_lite_req.w.data   ),
    .s_axi_wvalid  ( clint_lite_req.w_valid  ),
    .s_axi_wready  ( clint_lite_rsp.w_ready  ),
    .s_axi_bresp   ( clint_lite_rsp.b.resp   ),
    .s_axi_bvalid  ( clint_lite_rsp.b_valid  ),
    .s_axi_bready  ( clint_lite_req.b_ready  ),
    .s_axi_araddr  ( clint_lite_req.ar.addr  ),
    .s_axi_arvalid ( clint_lite_req.ar_valid ),
    .s_axi_arready ( clint_lite_rsp.ar_ready ),
    .s_axi_rdata   ( clint_lite_rsp.r.data   ),
    .s_axi_rresp   ( clint_lite_rsp.r.resp   ),
    .s_axi_rvalid  ( clint_lite_rsp.r_valid  ),
    .s_axi_rready  ( clint_lite_req.r_ready  )
);

endmodule

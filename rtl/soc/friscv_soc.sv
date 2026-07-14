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

module friscv_soc #(
    parameter int unsigned SramBase = 32'h0000_0000,
    parameter int unsigned SramSize = 32'h0000_4000,
    parameter int unsigned MemBase  = 32'h8000_0000,
    parameter int unsigned MemSize  = 32'h0100_0000,
    parameter int unsigned NumPads  = 22
) (
    input  logic  i_clk,
    input  logic  i_rstn,

    output logic  o_clk_out,

    output logic  o_end,

    // UART
    input  logic  i_uart_rx,
    output logic  o_uart_tx,

    // JTAG
    input  logic  i_jtag_tck,
    input  logic  i_jtag_tms,
    input  logic  i_jtag_tdi,
    output logic  o_jtag_tdo,

    // PA0
    input  logic  i_pa0,
    output logic  o_pa0,
    output logic  o_pa0_oe,

    // PA1
    input  logic  i_pa1,
    output logic  o_pa1,
    output logic  o_pa1_oe,

    // PA2
    input  logic  i_pa2,
    output logic  o_pa2,
    output logic  o_pa2_oe,

    // Muxed pins
    input  logic [NumPads-1:0] pad_in_i,
    output logic [NumPads-1:0] pad_out_o,
    output logic [NumPads-1:0] pad_oe_o
);

// Provide clock divided by 16 to the outside
logic [3:0] clk_cnt;
always_ff @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn) clk_cnt <= '0;
    else         clk_cnt <= clk_cnt + 1;
end
assign o_clk_out = clk_cnt[3];

// ============================================================
// CPU subsystem
// ============================================================

friscv_mem_if cpu_if ();

logic [63:0] mtime;
logic        msip, mtip, meip, seip;

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
    .RAM_BASE            ( MemBase       ),
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
    .i_seip    ( seip      ),
    .i_mtime   ( mtime     ),
    .mem_if    ( cpu_if    ),
    .i_dbg_req ( debug_req )
);

// ============================================================
// Memory hub {cpu, dm} -> {soc, mem}
// ============================================================

friscv_mem_if dm_if ();
friscv_mem_if mem_if ();
friscv_mem_if soc_if ();

friscv_mem_hub #(
    .MEM_BASE( SramBase ),
    .MEM_SIZE( SramSize )
 ) friscv_mem_hub (
    .i_clk    ( i_clk    ),
    .i_rstn   ( soc_rstn ),
    .s_cpu_if ( cpu_if   ),
    .s_dm_if  ( dm_if    ),
    .m_mem_if ( mem_if   ),
    .m_soc_if ( soc_if   )
);

// ============================================================
// Interconnect: flat AXI-Lite -> AXI_LITE -> lite xbar -> {RAM, peripherals}
// ============================================================

localparam int unsigned AxiAddrWidth = 32;
localparam int unsigned AxiDataWidth = 32;
localparam int unsigned AxiIdWidth   = 1;
localparam int unsigned AxiUserWidth = 1;

// Lite crossbar port map:
//  Slave  port 0: MEM hub
//  ---------------------
//  Master port 0: CLINT
//  Master port 1: Peripheral regs
localparam int unsigned NumAxiLiteSlv   = 1;
localparam int unsigned CpuPort         = 0;

localparam int unsigned NumAxiLiteMst   = 2;
localparam int unsigned NumAxiLiteRules = 1;
localparam int unsigned ClintPort       = 0;
localparam int unsigned RegsPort        = 1;

localparam int unsigned LiteMstIdxW = $clog2(NumAxiLiteMst);

localparam axi_pkg::xbar_cfg_t AxiLiteXbarCfg = '{
    NoSlvPorts:         NumAxiLiteSlv,
    NoMstPorts:         NumAxiLiteMst,
    MaxMstTrans:        1,
    MaxSlvTrans:        1,
    FallThrough:        1'b0,
    LatencyMode:        axi_pkg::NO_LATENCY,
    PipelineStages:     0,
    AxiIdWidthSlvPorts: 0,
    AxiIdUsedSlvPorts:  0,
    UniqueIds:          1'b0,
    AxiAddrWidth:       AxiAddrWidth,
    AxiDataWidth:       AxiDataWidth,
    NoAddrRules:        NumAxiLiteRules
};

// Address decode
// idx is the target master-port index
// To keep the address decoder small, all transfers that are not for the CLINT or SRAM are
// sent to the peripheral regs port.
localparam axi_pkg::xbar_rule_32_t [NumAxiLiteRules-1:0] AxiLiteAddrMap = '{
    '{ idx: ClintPort, start_addr: 32'h0200_0000, end_addr: 32'h0201_0000 }     // CLINT
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

friscv_axi_lite_adapter_intf m_soc (
    .clk_i   ( i_clk                      ),
    .rst_ni  ( soc_rstn                   ),
    .mem_slv ( soc_if                     ),
    .mst     ( axi_lite_xbar_slv[CpuPort] )
);

// The AXI-Lite xbar
axi_lite_xbar_intf #(
    .Cfg    ( AxiLiteXbarCfg          ),
    .rule_t ( axi_pkg::xbar_rule_32_t )
) axi_lite_xbar (
    .clk_i                 ( i_clk                                   ),
    .rst_ni                ( soc_rstn                                ),
    .test_i                ( 1'b0                                    ),
    .slv_ports             ( axi_lite_xbar_slv                       ),
    .mst_ports             ( axi_lite_xbar_mst                       ),
    .addr_map_i            ( AxiLiteAddrMap                          ),
    .en_default_mst_port_i ( '1                                      ),
    .default_mst_port_i    ( {NumAxiLiteSlv{LiteMstIdxW'(RegsPort)}} )  // Send everything else to regs
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

localparam int unsigned NoRegPorts   = 7;
localparam int unsigned DmPort       = 0;
localparam int unsigned Uart0Port    = 1;
localparam int unsigned ScratchPort  = 2;
localparam int unsigned GpioAPort    = 3;
localparam int unsigned PlicPort     = 4;
localparam int unsigned PinmuxPort   = 5;
localparam int unsigned ErrPort      = 6;

reg_bus_req_t [NoRegPorts-1:0] reg_dev_req;
reg_bus_rsp_t [NoRegPorts-1:0] reg_dev_rsp;

localparam int unsigned NoRegRules = 6;
localparam axi_pkg::xbar_rule_32_t [NoRegRules-1:0] RegAddrMap = '{
    '{ idx: DmPort,      start_addr: DmBaseAddr,    end_addr: DmBaseAddr + DmSize },
    '{ idx: PlicPort,    start_addr: 32'h0C00_0000, end_addr: 32'h0C20_2000 },
    '{ idx: Uart0Port,   start_addr: 32'h1000_0000, end_addr: 32'h1000_1000 },
    '{ idx: GpioAPort,   start_addr: 32'h2000_0000, end_addr: 32'h2000_0040 },
    '{ idx: PinmuxPort,  start_addr: 32'h3000_0000, end_addr: 32'h3000_0040 },
    '{ idx: ScratchPort, start_addr: 32'h4000_0000, end_addr: 32'h4000_0004 }
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
    .default_idx_i    ( 3'(ErrPort)       )
);

assign reg_dev_rsp[ErrPort].rdata = '0;
assign reg_dev_rsp[ErrPort].error = 1'b1;
assign reg_dev_rsp[ErrPort].ready = 1'b1;

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
// Scratch register
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

AXI_BUS #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
) mem_axi ();

friscv_axi4_full_adapter_intf #(
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
) m_mem (
    .clk_i          ( i_clk    ),
    .rst_ni         ( soc_rstn ),
    .mem_slv        ( mem_if   ),
    .mst            ( mem_axi  )
);

logic        sram_req, sram_gnt, sram_we, sram_rvalid;
logic [31:0] sram_addr, sram_wdata, sram_rdata;
logic [3:0]  sram_be;

axi_to_mem_intf #(
    .ADDR_WIDTH ( AxiAddrWidth ),
    .DATA_WIDTH ( AxiDataWidth ),
    .ID_WIDTH   ( AxiIdWidth   ),
    .USER_WIDTH ( AxiUserWidth ),
    .NUM_BANKS  ( 1            )
) axi_to_mem (
    .clk_i        ( i_clk       ),
    .rst_ni       ( soc_rstn    ),
    .busy_o       (             ),
    .slv          ( mem_axi     ),
    .mem_req_o    ( sram_req    ),
    .mem_gnt_i    ( sram_gnt    ),
    .mem_addr_o   ( sram_addr   ),
    .mem_wdata_o  ( sram_wdata  ),
    .mem_strb_o   ( sram_be     ),
    .mem_atop_o   (             ),
    .mem_we_o     ( sram_we     ),
    .mem_rvalid_i ( sram_rvalid ),
    .mem_rdata_i  ( sram_rdata  )
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

// DM SBA master port: dm master -> bridge -> mem hub DM port
friscv_dm_sba_mem dm_sba_mem (
    .i_clk          ( i_clk         ),
    .i_rstn         ( soc_rstn      ),
    .dm_req_i       ( sba_req       ),
    .dm_addr_i      ( sba_addr      ),
    .dm_we_i        ( sba_we        ),
    .dm_wdata_i     ( sba_wdata     ),
    .dm_be_i        ( sba_be        ),
    .dm_gnt_o       ( sba_gnt       ),
    .dm_rvalid_o    ( sba_rvalid    ),
    .dm_err_o       ( sba_err       ),
    .dm_other_err_o ( sba_other_err ),
    .dm_rdata_o     ( sba_rdata     ),
    .mem_if         ( dm_if         )
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

logic uart0_irq;

// APB -> 16550 UART
apb_uart_wrap #(
    .apb_req_t ( apb_req_t  ),
    .apb_rsp_t ( apb_resp_t )
) uart0 (
    .clk_i     ( i_clk         ),
    .rst_ni    ( soc_rstn      ),
    .apb_req_i ( uart0_apb_req ),
    .apb_rsp_o ( uart0_apb_rsp ),
    .intr_o    ( uart0_irq     ),
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
// Pin mux
// ============================================================

/*
Pin#  Function 0  Function 1
3     PA3         -
4     PA4         -
5     PA5         -
6     PA6         -
7     PA7         -
8     PA8         -
9     PA9         -
10    PA10        -
11    PA11        -
12    PA12        -
13    PA13        -
14    PA14        -
15    PA15        -
16    PA16        -
17    PA17        -
18    PA18        -
19    PA19        -
20    PA20        -
21    PA21        -
22    PA22        -
23    PA23        -
24    PA24        -
*/

localparam int unsigned NumAfs = 2;

logic [NumPads-1:0][NumAfs-1:0] to_func;
logic [NumPads-1:0][NumAfs-1:0] from_func;
logic [NumPads-1:0][NumAfs-1:0] oe_func;

friscv_pinmux #(
    .NumPads  ( NumPads       ),
    .NumAfs   ( NumAfs        ),
    .AfInIdle ( '0            ),  // Idle level presented to non-selected AFs, all 0
    .reg_req_t( reg_bus_req_t ),
    .reg_rsp_t( reg_bus_rsp_t )
 ) pinmux (
    .clk_i      ( i_clk                   ),
    .rst_ni     ( i_rstn                  ),
    .reg_req_i  ( reg_dev_req[PinmuxPort] ),
    .reg_rsp_o  ( reg_dev_rsp[PinmuxPort] ),
    .pad_in_i   ( pad_in_i                ),
    .pad_out_o  ( pad_out_o               ),
    .pad_oe_o   ( pad_oe_o                ),
    .func_out_i ( from_func               ),  // peripheral -> pinmux
    .func_in_o  ( to_func                 ),  // peripheral <- pinmux
    .func_oe_i  ( oe_func                 )
);

// ============================================================
// GPIO Port A
// ============================================================

logic [31:0] gpio_a_irq;
logic [31:0] gpio_a_in;
logic [31:0] gpio_a_out;
logic [31:0] gpio_a_oe;

for (genvar p = 3; p <= 24; p++) begin : gpio_a_muxed
    assign from_func[p-3][0] = gpio_a_out[p];
    assign from_func[p-3][1] = 1'b0;  // no alternate function
    assign oe_func  [p-3][0] = gpio_a_oe[p];
    assign oe_func  [p-3][1] = 1'b0;  // no alternate function
    assign gpio_a_in[p]      = to_func[p-3][0];
end

gpio #(
    .reg_req_t   ( reg_bus_req_t ),
    .reg_rsp_t   ( reg_bus_rsp_t ),
    .GpioAsyncOn ( 1             )
) gpio_a (
    .clk_i         ( i_clk                  ),
    .rst_ni        ( soc_rstn               ),
    .reg_req_i     ( reg_dev_req[GpioAPort] ),
    .reg_rsp_o     ( reg_dev_rsp[GpioAPort] ),
    .intr_gpio_o   ( gpio_a_irq             ),
    .cio_gpio_i    ( gpio_a_in              ),
    .cio_gpio_o    ( gpio_a_out             ),
    .cio_gpio_en_o ( gpio_a_oe              )
);

// PA0
assign gpio_a_in[0] = i_pa0;
assign o_pa0        = gpio_a_out[0];
assign o_pa0_oe     = gpio_a_oe[0];

// PA1
assign gpio_a_in[1] = i_pa1;
assign o_pa1        = gpio_a_out[1];
assign o_pa1_oe     = gpio_a_oe[1];

// PA2
assign gpio_a_in[2] = i_pa2;
assign o_pa2        = gpio_a_out[2];
assign o_pa2_oe     = gpio_a_oe[2];

// ============================================================
// PLIC
// ============================================================

localparam int unsigned NIrqSources = 8;
logic [NIrqSources-1:0] plic_irq_sources;
assign plic_irq_sources[0] = 1'b0;  // reserved
assign plic_irq_sources[1] = uart0_irq;
assign plic_irq_sources[2] = 1'b0;
assign plic_irq_sources[3] = 1'b0;
// GPIO 19-22 can be used as external interrupts
assign plic_irq_sources[4] = gpio_a_irq[19];
assign plic_irq_sources[5] = gpio_a_irq[20];
assign plic_irq_sources[6] = gpio_a_irq[21];
assign plic_irq_sources[7] = gpio_a_irq[22];

// Two targets, context 0 is hart 0 M-mode (MEIP), context 1 is hart 0 S-mode (SEIP)
localparam int unsigned NIrqTargets = 2;
logic [NIrqTargets-1:0] plic_irq_targets;
assign meip = plic_irq_targets[0];
assign seip = plic_irq_targets[1];

plic_top #(
    .N_SOURCE  ( NIrqSources   ),
    .N_TARGET  ( NIrqTargets   ),
    .MAX_PRIO  ( 1             ),
    .reg_req_t ( reg_bus_req_t ),
    .reg_rsp_t ( reg_bus_rsp_t )
) plic (
    .clk_i         ( i_clk                 ),
    .rst_ni        ( soc_rstn              ),
    .req_i         ( reg_dev_req[PlicPort] ),
    .resp_o        ( reg_dev_rsp[PlicPort] ),
    .le_i          ( '0                    ),  // All level-held
    .irq_sources_i ( plic_irq_sources      ),
    .eip_targets_o ( plic_irq_targets      )
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

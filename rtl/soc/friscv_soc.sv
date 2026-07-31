// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at
//
//     https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "axi/typedef.svh"
`include "axi/assign.svh"
`include "register_interface/typedef.svh"
`include "apb/typedef.svh"

`timescale 1ns/1ps

module friscv_soc #(
    parameter int unsigned SramBase          = 32'h0000_0000,
    parameter int unsigned SramSize          = 32'h0000_4000,
    parameter int unsigned MemBase           = 32'h8000_0000,
    parameter int unsigned MemSize           = 32'h0100_0000,
    parameter int unsigned LineBytes         = 64,
    parameter int unsigned Ways              = 4,
    parameter bit          HyperClockDelayed = 1'b1,
    parameter int unsigned NumPads           = 25,
    parameter bit          EnablePlic        = 1,
    parameter int unsigned ClkFreqHz         = 50_000_000,
    parameter int unsigned ZsblRomSizeBytes  = 64
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

    // GPIO Port A muxed pads (PA0..PA24)
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
    .RAM_BASE            ( MemBase          ),
    .ZSBL_ROM_SIZE_BYTES ( ZsblRomSizeBytes ),
    .ZSBL_BASE           ( 32'h20000        ),
    .DM_BASE             ( DmBaseAddr       )
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

logic [Ways-1:0] llcsel;
logic            crpsel;
logic            llcinv;

friscv_mem_if dm_if ();
friscv_mem_if ext_if ();
friscv_mem_if soc_if ();

friscv_mem_hub #(
    .MEM_BASE   ( MemBase   ),
    .MEM_SIZE   ( MemSize   ),
    .SRAM_BASE  ( SramBase  ),
    .SRAM_SIZE  ( SramSize  ),
    .LINE_BYTES ( LineBytes ),
    .WAYS       ( Ways      )
) friscv_mem_hub (
    .i_clk    ( i_clk    ),
    .i_rstn   ( soc_rstn ),
    .s_cpu_if ( cpu_if   ),
    .s_dm_if  ( dm_if    ),
    .m_ext_if ( ext_if   ),
    .m_sys_if ( soc_if   ),
    .i_llcsel ( llcsel   ),
    .i_crpsel ( crpsel   ),
    .i_llcinv ( llcinv   )
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
    .clk_i          ( i_clk         ),
    .rst_ni         ( soc_rstn      ),
    .axi_lite_req_i ( regs_lite_req ),
    .axi_lite_rsp_o ( regs_lite_rsp ),
    .reg_req_o      ( regs_reg_req  ),
    .reg_rsp_i      ( regs_reg_rsp  )
);

localparam int unsigned NoRegPorts   = 9;
localparam int unsigned RegPortWidth = $clog2(NoRegPorts);

localparam int unsigned DmPort       = 0;
localparam int unsigned Uart0Port    = 1;
localparam int unsigned ScbPort      = 2;
localparam int unsigned GpioAPort    = 3;
localparam int unsigned PlicPort     = 4;
localparam int unsigned PinmuxPort   = 5;
localparam int unsigned HyperCfgPort = 6;
localparam int unsigned Qspi0Port    = 7;
localparam int unsigned ErrPort      = 8;

reg_bus_req_t [NoRegPorts-1:0] reg_dev_req;
reg_bus_rsp_t [NoRegPorts-1:0] reg_dev_rsp;

`define REG_TIE_OFF(port)                   \
    assign reg_dev_rsp[port].rdata = '0;    \
    assign reg_dev_rsp[port].error = 1'b1;  \
    assign reg_dev_rsp[port].ready = 1'b1;

localparam int unsigned NoRegRules = 8;
localparam axi_pkg::xbar_rule_32_t [NoRegRules-1:0] RegAddrMap = '{
    '{ idx: DmPort,       start_addr: DmBaseAddr,    end_addr: DmBaseAddr + DmSize },
    '{ idx: PlicPort,     start_addr: 32'h0C00_0000, end_addr: 32'h0C20_2000 },
    '{ idx: Uart0Port,    start_addr: 32'h1000_0000, end_addr: 32'h1000_1000 },
    '{ idx: GpioAPort,    start_addr: 32'h2000_0000, end_addr: 32'h2000_0040 },
    '{ idx: ScbPort,      start_addr: 32'h4000_0000, end_addr: 32'h4000_1000 },
    '{ idx: PinmuxPort,   start_addr: 32'h4000_1000, end_addr: 32'h4000_2000 },
    '{ idx: HyperCfgPort, start_addr: 32'h5001_0000, end_addr: 32'h5001_1000 },
    '{ idx: Qspi0Port,    start_addr: 32'h6000_0000, end_addr: 32'h6000_1000 }
};

logic [$clog2(NoRegPorts)-1:0] reg_select;
addr_decode #(
    .NoIndices ( NoRegPorts              ),
    .NoRules   ( NoRegRules              ),
    .addr_t    ( addr_t                  ),
    .rule_t    ( axi_pkg::xbar_rule_32_t )
) reg_decode (
    .addr_i           ( regs_reg_req.addr        ),
    .addr_map_i       ( RegAddrMap               ),
    .idx_o            ( reg_select               ),
    .dec_valid_o      (                          ),
    .dec_error_o      (                          ),
    .en_default_idx_i ( 1'b1                     ),
    .default_idx_i    ( (RegPortWidth)'(ErrPort) )
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
// System Control Block
// ============================================================

logic hb_en;  // HBCTL.HB_EN drives the AFX and the external memory guard

friscv_scb #(
    .NumPads    ( NumPads       ),
    .reg_req_t  ( reg_bus_req_t ),
    .reg_rsp_t  ( reg_bus_rsp_t ),
    .OcmLlcWays ( Ways          )
) scb (
    .clk_i     ( i_clk                ),
    .rst_ni    ( soc_rstn             ),
    .reg_req_i ( reg_dev_req[ScbPort] ),
    .reg_rsp_o ( reg_dev_rsp[ScbPort] ),
    .strap_i   ( pad_in_i             ),
    .o_hb_en   ( hb_en                ),
    .o_llcsel  ( llcsel               ),
    .o_crpsel  ( crpsel               ),
    .o_llcinv  ( llcinv               )
);

// ============================================================
// External memory interface
// ============================================================

logic       hb_ck, hb_ck_n, hb_cs_n, hb_reset_n;
logic       hb_rwds_o, hb_rwds_i, hb_rwds_oe;
logic [7:0] hb_dq_o, hb_dq_i;
logic       hb_dq_oe;

// Guarded external port
friscv_mem_if hyper_mem_if ();

friscv_hb_guard hb_guard (
    .i_hb_en ( hb_en        ),
    .s_if    ( ext_if       ),
    .m_if    ( hyper_mem_if )
);

AXI_BUS #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
) mem_axi ();

friscv_axi4_full_adapter_intf #(
    .BURST_LEN      ( LineBytes / (AxiDataWidth/8) ),
    .AXI_ID_WIDTH   ( AxiIdWidth                   ),
    .AXI_USER_WIDTH ( AxiUserWidth                 )
) m_mem (
    .clk_i          ( i_clk        ),
    .rst_ni         ( soc_rstn     ),
    .mem_slv        ( hyper_mem_if ),
    .mst            ( mem_axi      )
);

typedef logic [AxiIdWidth-1:0]   axi_id_t;
typedef logic [AxiUserWidth-1:0] axi_user_t;
typedef logic [3:0] axi_strb_t;

`AXI_TYPEDEF_ALL(hyper_axi, addr_t, axi_id_t, data_t, axi_strb_t, axi_user_t)

hyper_axi_req_t  hyper_axi_req;
hyper_axi_resp_t hyper_axi_rsp;
`AXI_ASSIGN_TO_REQ(hyper_axi_req,  mem_axi)
`AXI_ASSIGN_FROM_RESP(mem_axi, hyper_axi_rsp)

hyperbus #(
    .NumChips        ( 1                       ),
    .NumPhys         ( 1                       ),
    .IsClockODelayed ( HyperClockDelayed       ),
    .AxiAddrWidth    ( AxiAddrWidth            ),
    .AxiDataWidth    ( AxiDataWidth            ),
    .AxiIdWidth      ( AxiIdWidth              ),
    .AxiUserWidth    ( AxiUserWidth            ),
    .axi_req_t       ( hyper_axi_req_t         ),
    .axi_rsp_t       ( hyper_axi_resp_t        ),
    .axi_w_chan_t    ( hyper_axi_w_chan_t      ),
    .axi_b_chan_t    ( hyper_axi_b_chan_t      ),
    .axi_ar_chan_t   ( hyper_axi_ar_chan_t     ),
    .axi_r_chan_t    ( hyper_axi_r_chan_t      ),
    .axi_aw_chan_t   ( hyper_axi_aw_chan_t     ),
    .RegAddrWidth    ( 32                      ),
    .RegDataWidth    ( 32                      ),
    .reg_req_t       ( reg_bus_req_t           ),
    .reg_rsp_t       ( reg_bus_rsp_t           ),
    .axi_rule_t      ( axi_pkg::xbar_rule_32_t ),
    .MinFreqMHz      ( 40                      ),
    .RstChipBase     ( MemBase                 ),
    .RstChipSpace    ( 32'h0080_0000           ),
    .AxiLogDepth     ( 1                       )
) i_hyperbus (
    .clk_phy_i       ( i_clk                     ),
    .rst_phy_ni      ( soc_rstn                  ),
    .clk_sys_i       ( i_clk                     ),
    .rst_sys_ni      ( soc_rstn                  ),
    .test_mode_i     ( 1'b0                      ),
    .axi_req_i       ( hyper_axi_req             ),
    .axi_rsp_o       ( hyper_axi_rsp             ),
    .reg_req_i       ( reg_dev_req[HyperCfgPort] ),
    .reg_rsp_o       ( reg_dev_rsp[HyperCfgPort] ),
    .hyper_cs_no     ( hb_cs_n                   ),
    .hyper_ck_o      ( hb_ck                     ),
    .hyper_ck_no     ( hb_ck_n                   ),  // single-ended: no package pin
    .hyper_rwds_o    ( hb_rwds_o                 ),
    .hyper_rwds_i    ( hb_rwds_i                 ),
    .hyper_rwds_oe_o ( hb_rwds_oe                ),
    .hyper_dq_i      ( hb_dq_i                   ),
    .hyper_dq_o      ( hb_dq_o                   ),
    .hyper_dq_oe_o   ( hb_dq_oe                  ),
    .hyper_reset_no  ( hb_reset_n                )
);

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
friscv_from_mem dm_sba_mem (
    .i_clk       ( i_clk         ),
    .i_rstn      ( soc_rstn      ),
    .req_i       ( sba_req       ),
    .addr_i      ( sba_addr      ),
    .we_i        ( sba_we        ),
    .wdata_i     ( sba_wdata     ),
    .be_i        ( sba_be        ),
    .gnt_o       ( sba_gnt       ),
    .rvalid_o    ( sba_rvalid    ),
    .err_o       ( sba_err       ),
    .other_err_o ( sba_other_err ),
    .rdata_o     ( sba_rdata     ),
    .mem_if      ( dm_if         )
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
Pad   AF0        AF1        AFX (HB_EN)  Notes
----  ---------  ---------  -----------  -------------------------
PA0   gpio[0]    -          -
PA1   gpio[1]    -          -            external interrupt
PA2   gpio[2]    -          -            external interrupt
PA3   gpio[3]    -          -            external interrupt
PA4   gpio[4]    -          -            external interrupt
PA5   gpio[5]    QSPI0_IO0  -
PA6   gpio[6]    QSPI0_IO1  -
PA7   gpio[7]    QSPI0_IO2  -            boot strap
PA8   gpio[8]    QSPI0_IO3  -            boot strap
PA9   gpio[9]    QSPI0_SCK  -
PA10  gpio[10]   QSPI0_CS0  -
PA11  gpio[11]   QSPI0_CS1  -
PA12  gpio[12]   QSPI0_CS2  -
PA13  gpio[13]   DBG_D0     HB_DQ0
PA14  gpio[14]   DBG_D1     HB_DQ1
PA15  gpio[15]   DBG_D2     HB_DQ2
PA16  gpio[16]   DBG_D3     HB_DQ3
PA17  gpio[17]   DBG_D4     HB_DQ4
PA18  gpio[18]   DBG_D5     HB_DQ5
PA19  gpio[19]   DBG_D6     HB_DQ6
PA20  gpio[20]   DBG_D7     HB_DQ7
PA21  gpio[21]   DBG_SEL0   HB_RWDS
PA22  gpio[22]   DBG_SEL1   HB_CK
PA23  gpio[23]   DBG_SEL2   HB_CS0_N
PA24  gpio[24]   DBG_SEL3   HB_RST_N
*/

localparam int unsigned NumAfs = 2;

// HyperBus pad assignment for the AFX overlay
localparam int unsigned PadHbDqLsb = 13;  // PA13..PA20 = HB_DQ0..HB_DQ7
localparam int unsigned PadHbRwds  = 21;  // PA21 = HB_RWDS
localparam int unsigned PadHbCk    = 22;  // PA22 = HB_CK
localparam int unsigned PadHbCsN   = 23;  // PA23 = HB_CS0_N
localparam int unsigned PadHbRstN  = 24;  // PA24 = HB_RST_N

logic [NumPads-1:0][NumAfs-1:0] to_func;
logic [NumPads-1:0][NumAfs-1:0] from_func;
logic [NumPads-1:0][NumAfs-1:0] oe_func;

logic [NumPads-1:0] pm_pad_out, pm_pad_oe;

// Region-relative pinmux register address
reg_bus_req_t pinmux_req;
always_comb begin
    pinmux_req      = reg_dev_req[PinmuxPort];
    pinmux_req.addr = reg_dev_req[PinmuxPort].addr & 32'h0000_0FFF;
end

friscv_pinmux #(
    .NumPads  ( NumPads       ),
    .NumAfs   ( NumAfs        ),
    .AfInIdle ( '0            ),  // Idle level presented to non-selected AFs, all 0
    .reg_req_t( reg_bus_req_t ),
    .reg_rsp_t( reg_bus_rsp_t )
 ) pinmux (
    .clk_i      ( i_clk                   ),
    .rst_ni     ( i_rstn                  ),
    .reg_req_i  ( pinmux_req              ),
    .reg_rsp_o  ( reg_dev_rsp[PinmuxPort] ),
    .pad_in_i   ( pad_in_i                ),
    .pad_out_o  ( pm_pad_out              ),
    .pad_oe_o   ( pm_pad_oe               ),
    .func_out_i ( from_func               ),  // peripheral -> pinmux
    .func_in_o  ( to_func                 ),  // peripheral <- pinmux
    .func_oe_i  ( oe_func                 )
);

// ============================================================
// AFX Switch
// ============================================================

assign hb_dq_i   = pad_in_i[PadHbDqLsb +: 8];  // PA13..PA20
assign hb_rwds_i = pad_in_i[PadHbRwds];        // PA21

always_comb begin
    pad_out_o = pm_pad_out;
    pad_oe_o  = pm_pad_oe;

    if (hb_en) begin
        // DQ[7:0] on PA13..PA20 bidirectional with one shared output enable
        for (int unsigned i = 0; i < 8; i++) begin
            pad_out_o[PadHbDqLsb + i] = hb_dq_o[i];
            pad_oe_o [PadHbDqLsb + i] = hb_dq_oe;
        end
        // RWDS on PA21 bidirectional
        pad_out_o[PadHbRwds] = hb_rwds_o;
        pad_oe_o [PadHbRwds] = hb_rwds_oe;
        // CK / CS0_N / RST_N on PA22..PA24 output only
        pad_out_o[PadHbCk]   = hb_ck;
        pad_oe_o [PadHbCk]   = 1'b1;
        pad_out_o[PadHbCsN]  = hb_cs_n;
        pad_oe_o [PadHbCsN]  = 1'b1;
        pad_out_o[PadHbRstN] = hb_reset_n;
        pad_oe_o [PadHbRstN] = 1'b1;
    end
end

// ============================================================
// GPIO Port A
// ============================================================

logic [31:0] gpio_a_irq;
logic [31:0] gpio_a_in;
logic [31:0] gpio_a_out;
logic [31:0] gpio_a_oe;

for (genvar p = 0; p < NumPads; p++) begin : gpio_a_af0
    assign from_func[p][0] = gpio_a_out[p];
    assign oe_func  [p][0] = gpio_a_oe [p];
    assign gpio_a_in[p]    = to_func[p][0];
end

// GPIO bits without a pad are unused
assign gpio_a_in[31:NumPads] = '0;

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

// ============================================================
// QSPI0
// ============================================================

localparam int unsigned Qspi0NumCs   = 3;  // CS0, CS1, CS2
localparam int unsigned Qspi0PadBase = 5;  // First muxed pad (PA5 = IO0)

logic                  qspi0_sck, qspi0_sck_oe;
logic [Qspi0NumCs-1:0] qspi0_cs,  qspi0_cs_oe;
logic [3:0]            qspi0_sd_i, qspi0_sd_o, qspi0_sd_oe;
logic                  qspi0_irq_error, qspi0_irq_spi_event;

spi_host #(
    .reg_req_t ( reg_bus_req_t ),
    .reg_rsp_t ( reg_bus_rsp_t )
) qspi0 (
    .clk_i            ( i_clk                  ),
    .rst_ni           ( soc_rstn               ),
    .reg_req_i        ( reg_dev_req[Qspi0Port] ),
    .reg_rsp_o        ( reg_dev_rsp[Qspi0Port] ),
    .cio_sck_o        ( qspi0_sck              ),
    .cio_sck_en_o     ( qspi0_sck_oe           ),
    .cio_csb_o        ( qspi0_cs               ),
    .cio_csb_en_o     ( qspi0_cs_oe            ),
    .cio_sd_o         ( qspi0_sd_o             ),
    .cio_sd_en_o      ( qspi0_sd_oe            ),
    .cio_sd_i         ( qspi0_sd_i             ),
    .intr_error_o     ( qspi0_irq_error        ),
    .intr_spi_event_o ( qspi0_irq_spi_event    )
);

// Data lines PA5..PA8 (bidirectional)
for (genvar i = 0; i < 4; i++) begin : gen_qspi0_io
    assign from_func[Qspi0PadBase + i][1] = qspi0_sd_o [i];
    assign oe_func  [Qspi0PadBase + i][1] = qspi0_sd_oe[i];
    assign qspi0_sd_i[i]                  = to_func[Qspi0PadBase + i][1];
end

// SCK on PA9 (output only)
assign from_func[9][1] = qspi0_sck;
assign oe_func  [9][1] = qspi0_sck_oe;

// Chip selects PA10..PA12 (outputs only)
for (genvar i = 0; i < Qspi0NumCs; i++) begin : gen_qspi0_cs
    assign from_func[10 + i][1] = qspi0_cs   [i];
    assign oe_func  [10 + i][1] = qspi0_cs_oe[i];
end

// Pads PA0..PA4 have no alternate function, AF1 idle
for (genvar p = 0; p < Qspi0PadBase; p++) begin : gen_no_af1
    assign from_func[p][1] = 1'b0;
    assign oe_func  [p][1] = 1'b0;
end

// ============================================================
// Debug read port
// ============================================================

logic [3:0] dbg_sel;
logic [7:0] dbg_data;
logic [7:0] dbg_src [16];

assign dbg_sel = { to_func[PadHbRstN][1], to_func[PadHbCsN][1],
                   to_func[PadHbCk][1],   to_func[PadHbRwds][1] };

for (genvar i = 0; i < 16; i++) begin : gen_dbg_src
    assign dbg_src[i] = 8'h00;  // TODO tied to 0 for now
end
assign dbg_data = dbg_src[dbg_sel];

// DBG_D0..DBG_D7 drive PA13..PA20
for (genvar i = 0; i < 8; i++) begin : gen_dbg_d
    assign from_func[PadHbDqLsb + i][1] = dbg_data[i];
    assign oe_func  [PadHbDqLsb + i][1] = 1'b1;
end

// DBG_SEL0..DBG_SEL3 read PA21..PA24 output disabled, pad drives func_in
for (genvar i = 0; i < 4; i++) begin : gen_dbg_sel
    assign from_func[PadHbRwds + i][1] = 1'b0;
    assign oe_func  [PadHbRwds + i][1] = 1'b0;
end

// ============================================================
// PLIC
// ============================================================

localparam int unsigned NIrqSources = 8;
logic [NIrqSources-1:0] plic_irq_sources;
assign plic_irq_sources[0] = 1'b0;  // reserved
assign plic_irq_sources[1] = uart0_irq;
assign plic_irq_sources[2] = qspi0_irq_error;
assign plic_irq_sources[3] = qspi0_irq_spi_event;
// PA1..PA4 can be used as external interrupts
assign plic_irq_sources[4] = gpio_a_irq[1];
assign plic_irq_sources[5] = gpio_a_irq[2];
assign plic_irq_sources[6] = gpio_a_irq[3];
assign plic_irq_sources[7] = gpio_a_irq[4];

// Two targets, context 0 is hart 0 M-mode (MEIP), context 1 is hart 0 S-mode (SEIP)
localparam int unsigned NIrqTargets = 2;
logic [NIrqTargets-1:0] plic_irq_targets;
assign meip = plic_irq_targets[0];
assign seip = plic_irq_targets[1];

if (EnablePlic) begin : gen_plic
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
end else begin : gen_no_plic
    `REG_TIE_OFF(PlicPort)
    assign plic_irq_targets = '0;
end

// ============================================================
// CLINT: Lite xbar port -> AXI-Lite -> CLINT
// ============================================================

axi_lite_req_t  clint_lite_req;
axi_lite_resp_t clint_lite_rsp;
`AXI_LITE_ASSIGN_TO_REQ   (clint_lite_req, axi_lite_xbar_mst[ClintPort])
`AXI_LITE_ASSIGN_FROM_RESP(axi_lite_xbar_mst[ClintPort], clint_lite_rsp)

friscv_clint #(
    .CLK_FREQ_HZ   ( ClkFreqHz  ),
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

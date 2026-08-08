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

`include "axi/assign.svh"
`include "apb/typedef.svh"

`timescale 1ns/1ps

module friscv_soc import friscv_soc_pkg::*, axi_pkg::xbar_rule_32_t, dm::hartinfo_t; #(
    parameter int unsigned SramBase         = 32'h0000_0000,
    parameter int unsigned SramSize         = 32'h0000_2000,
    parameter int unsigned MemBase          = 32'h8000_0000,
    parameter int unsigned MemSize          = 32'h0100_0000,
    parameter int unsigned LineBytes        = 32,
    parameter int unsigned Ways             = 4,
    parameter bit          SramTags         = 1'b1,
    parameter bit          EnablePlic       = 1,
    parameter int unsigned ZsblRomSizeBytes = 144,
    parameter int unsigned NumStraps        = 13,
    parameter int unsigned NumExtRegSlv     = 1,
    parameter axi_pkg::xbar_rule_32_t [NumExtRegSlv-1:0] ExtRegSlvRules = '{default: '0},
    parameter type axi_req_t = friscv_axi_req_t,
    parameter type axi_rsp_t = friscv_axi_resp_t,
    parameter type reg_req_t = friscv_reg_req_t,
    parameter type reg_rsp_t = friscv_reg_rsp_t
) (
    input  logic  i_clk,
    input  logic  i_rstn,

    output logic  o_por_rstn,
    output logic  o_soc_rstn,

    output logic  o_clk_out,

    output logic  o_end,

    // External memory
    output axi_req_t o_axi_mem_req,
    input  axi_rsp_t i_axi_mem_rsp,
    output logic     o_axi_mem_en,

    // External register slaves
    output reg_req_t [NumExtRegSlv-1:0] o_reg_ext_req,
    input  reg_rsp_t [NumExtRegSlv-1:0] i_reg_ext_rsp,

    // Straps
    input  logic [NumStraps-1:0] i_strap,

    // UART
    input  logic  i_uart_rx,
    output logic  o_uart_tx,

    // JTAG
    input  logic  i_jtag_tck,
    input  logic  i_jtag_tms,
    input  logic  i_jtag_tdi,
    output logic  o_jtag_tdo,

    // QSPI0
    output logic       o_qspi_sck,
    output logic       o_qspi_sck_oe,
    output logic [2:0] o_qspi_cs,
    output logic [2:0] o_qspi_cs_oe,
    output logic [3:0] o_qspi_sd,
    output logic [3:0] o_qspi_sd_oe,
    input  logic [3:0] i_qspi_sd,

    // GPIO Port A
    input  logic [31:0] i_gpio,
    output logic [31:0] o_gpio,
    output logic [31:0] o_gpio_oe
);

logic por_rstn;  // power-on reset synchronizer

rstgen i_rstgen (
    .clk_i       ( i_clk    ),
    .rst_ni      ( i_rstn   ),
    .test_mode_i ( 1'b0     ),
    .rst_no      ( por_rstn ),
    .init_no     (          )
);

// Provide clock divided by 16 to the outside
logic [3:0] clk_cnt;
always_ff @(posedge i_clk or negedge por_rstn) begin
    if (!por_rstn) clk_cnt <= '0;
    else           clk_cnt <= clk_cnt + 1;
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
assign soc_rstn = por_rstn & ~ndmreset;

assign o_por_rstn = por_rstn;
assign o_soc_rstn = soc_rstn;

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
    .WAYS       ( Ways      ),
    .SRAM_TAGS  ( SramTags  )
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
// Interconnect: mem_if -> mem -> reg_bus -> reg demux -> peripherals
// ============================================================

`APB_TYPEDEF_ALL(apb, addr_t, data_t, strb_t)

// mem_if -> mem
logic        soc_req, soc_gnt, soc_we, soc_rvalid, soc_err;
addr_t       soc_addr;
data_t       soc_wdata, soc_rdata;
logic [3:0]  soc_be;

friscv_to_mem #(
    .REGISTER_REQ ( 1 )
) soc_to_mem (
    .i_clk       ( i_clk      ),
    .i_rstn      ( soc_rstn   ),
    .req_o       ( soc_req    ),
    .addr_o      ( soc_addr   ),
    .we_o        ( soc_we     ),
    .wdata_o     ( soc_wdata  ),
    .be_o        ( soc_be     ),
    .gnt_i       ( soc_gnt    ),
    .rvalid_i    ( soc_rvalid ),
    .err_i       ( soc_err    ),
    .other_err_i ( 1'b0       ),
    .rdata_i     ( soc_rdata  ),
    .mem_if      ( soc_if     )
);

// mem -> reg_bus
reg_req_t regs_reg_req;
reg_rsp_t regs_reg_rsp;

mem_to_reg #(
    .AW        ( AddrWidth ),
    .DW        ( DataWidth ),
    .reg_req_t ( reg_req_t ),
    .reg_rsp_t ( reg_rsp_t )
) soc_mem_to_reg (
    .clk_i     ( i_clk        ),
    .rst_ni    ( soc_rstn     ),
    .req_i     ( soc_req      ),
    .gnt_o     ( soc_gnt      ),
    .we_i      ( soc_we       ),
    .addr_i    ( soc_addr     ),
    .wdata_i   ( soc_wdata    ),
    .be_i      ( soc_be       ),
    .rdata_o   ( soc_rdata    ),
    .rvalid_o  ( soc_rvalid   ),
    .err_o     ( soc_err      ),
    .reg_req_o ( regs_reg_req ),
    .reg_rsp_i ( regs_reg_rsp )
);

// ============================================================
// Reg demux
// ============================================================

localparam int unsigned DmPort    = 0;
localparam int unsigned Uart0Port = 1;
localparam int unsigned ScbPort   = 2;
localparam int unsigned GpioAPort = 3;
localparam int unsigned PlicPort  = 4;
localparam int unsigned Qspi0Port = 5;
localparam int unsigned ClintPort = 6;
localparam int unsigned ErrPort   = 7;

localparam int unsigned NoRegPorts   = NumIntRegPorts + NumExtRegSlv;
localparam int unsigned RegPortWidth = $clog2(NoRegPorts);

// MSWI + MTIMER + tick generator config + SSWI, the whole ACLINT map
localparam logic [31:0] ClintBaseAddr = 32'h0200_0000;
localparam logic [31:0] ClintSize     = 32'h0002_0000;

reg_req_t [NoRegPorts-1:0] reg_dev_req;
reg_rsp_t [NoRegPorts-1:0] reg_dev_rsp;

`define REG_TIE_OFF(port)                   \
    assign reg_dev_rsp[port].rdata = '0;    \
    assign reg_dev_rsp[port].error = 1'b1;  \
    assign reg_dev_rsp[port].ready = 1'b1;

localparam int unsigned NoIntRegRules = 7;
localparam int unsigned NoRegRules    = NoIntRegRules + NumExtRegSlv;

localparam xbar_rule_32_t [NoIntRegRules-1:0] IntRegRules = '{
    '{ idx: DmPort,    start_addr: DmBaseAddr,    end_addr: DmBaseAddr + DmSize },
    '{ idx: ClintPort, start_addr: ClintBaseAddr, end_addr: ClintBaseAddr + ClintSize },
    '{ idx: PlicPort,  start_addr: 32'h0C00_0000, end_addr: 32'h0C20_2000 },
    '{ idx: Uart0Port, start_addr: 32'h1000_0000, end_addr: 32'h1000_1000 },
    '{ idx: GpioAPort, start_addr: 32'h2000_0000, end_addr: 32'h2000_0040 },
    '{ idx: ScbPort,   start_addr: 32'h4000_0000, end_addr: 32'h4000_1000 },
    '{ idx: Qspi0Port, start_addr: 32'h6000_0000, end_addr: 32'h6000_1000 }
};

function automatic axi_pkg::xbar_rule_32_t [NoRegRules-1:0] gen_reg_rules();
    axi_pkg::xbar_rule_32_t rule;

    gen_reg_rules = '0;

    for (int i = 0; i < NoIntRegRules; i++) begin
        gen_reg_rules[i] = IntRegRules[i];
    end

    for (int i = 0; i < NumExtRegSlv; i++) begin
        rule     = ExtRegSlvRules[i];
        rule.idx = rule.idx + 32'(NumIntRegPorts);

        gen_reg_rules[NoIntRegRules + i] = rule;
    end
endfunction

localparam xbar_rule_32_t [NoRegRules-1:0] RegAddrMap = gen_reg_rules();

logic [RegPortWidth-1:0] reg_select;
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

`REG_TIE_OFF(ErrPort)

reg_demux #(
    .NoPorts ( NoRegPorts ),
    .req_t   ( reg_req_t  ),
    .rsp_t   ( reg_rsp_t  )
) reg_demux (
    .clk_i       ( i_clk        ),
    .rst_ni      ( soc_rstn     ),
    .in_select_i ( reg_select   ),
    .in_req_i    ( regs_reg_req ),
    .in_rsp_o    ( regs_reg_rsp ),
    .out_req_o   ( reg_dev_req  ),
    .out_rsp_i   ( reg_dev_rsp  )
);

for (genvar i = 0; i < NumExtRegSlv; i++) begin : gen_ext_reg
    assign o_reg_ext_req[i]                    = reg_dev_req[NumIntRegPorts + i];
    assign reg_dev_rsp[NumIntRegPorts + i]     = i_reg_ext_rsp[i];
end

// ============================================================
// System Control Block
// ============================================================

logic ext_mem_en;

friscv_scb #(
    .NumPads    ( NumStraps ),
    .reg_req_t  ( reg_req_t ),
    .reg_rsp_t  ( reg_rsp_t ),
    .OcmLlcWays ( Ways      )
) scb (
    .clk_i     ( i_clk                ),
    .rst_ni    ( soc_rstn             ),
    .reg_req_i ( reg_dev_req[ScbPort] ),
    .reg_rsp_o ( reg_dev_rsp[ScbPort] ),
    .strap_i   ( i_strap              ),
    .o_hb_en   ( ext_mem_en           ),
    .o_llcsel  ( llcsel               ),
    .o_crpsel  ( crpsel               ),
    .o_llcinv  ( llcinv               )
);

assign o_axi_mem_en = ext_mem_en;

// ============================================================
// External memory interface
// ============================================================

friscv_mem_if ext_guarded_if ();

friscv_ext_guard ext_guard (
    .i_en ( ext_mem_en     ),
    .s_if ( ext_if         ),
    .m_if ( ext_guarded_if )
);

AXI_BUS #(
    .AXI_ADDR_WIDTH ( AddrWidth    ),
    .AXI_DATA_WIDTH ( DataWidth    ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
) mem_axi ();

friscv_axi4_full_adapter_intf #(
    .BURST_LEN      ( LineBytes / StrbWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidth            ),
    .AXI_USER_WIDTH ( AxiUserWidth          )
) m_mem (
    .clk_i          ( i_clk          ),
    .rst_ni         ( soc_rstn       ),
    .mem_slv        ( ext_guarded_if ),
    .mst            ( mem_axi        )
);

`AXI_ASSIGN_TO_REQ(o_axi_mem_req, mem_axi)
`AXI_ASSIGN_FROM_RESP(mem_axi, i_axi_mem_rsp)

// ============================================================
// Debugger
// ============================================================

// DMI (DTM <-> DM) channel
logic dmi_rst, dmi_req_valid, dmi_req_ready;
dm::dmi_req_t  dmi_req;

logic dmi_resp_valid, dmi_resp_ready;
dm::dmi_resp_t dmi_resp;

// 2 scratch regs, memory-mapped data regs at dm::DataAddr.
localparam hartinfo_t HARTINFO = '{
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
    .rst_ni               ( por_rstn       ),

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
    .rst_ni           ( por_rstn       ),
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
    .AW    ( 32        ),
    .DW    ( 32        ),
    .req_t ( reg_req_t ),
    .rsp_t ( reg_rsp_t )
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
    .reg_req_t ( reg_req_t  ),
    .reg_rsp_t ( reg_rsp_t  ),
    .apb_req_t ( apb_req_t  ),
    .apb_rsp_t ( apb_resp_t )
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
// GPIO Port A
// ============================================================

logic [31:0] gpio_a_irq;

gpio #(
    .reg_req_t   ( reg_req_t ),
    .reg_rsp_t   ( reg_rsp_t ),
    .GpioAsyncOn ( 1         )
) gpio_a (
    .clk_i         ( i_clk                  ),
    .rst_ni        ( soc_rstn               ),
    .reg_req_i     ( reg_dev_req[GpioAPort] ),
    .reg_rsp_o     ( reg_dev_rsp[GpioAPort] ),
    .intr_gpio_o   ( gpio_a_irq             ),
    .cio_gpio_i    ( i_gpio                 ),
    .cio_gpio_o    ( o_gpio                 ),
    .cio_gpio_en_o ( o_gpio_oe              )
);

// ============================================================
// QSPI0
// ============================================================

logic qspi0_irq_error, qspi0_irq_spi_event;

spi_host #(
    .reg_req_t ( reg_req_t ),
    .reg_rsp_t ( reg_rsp_t )
) qspi0 (
    .clk_i            ( i_clk                  ),
    .rst_ni           ( soc_rstn               ),
    .reg_req_i        ( reg_dev_req[Qspi0Port] ),
    .reg_rsp_o        ( reg_dev_rsp[Qspi0Port] ),
    .cio_sck_o        ( o_qspi_sck             ),
    .cio_sck_en_o     ( o_qspi_sck_oe          ),
    .cio_csb_o        ( o_qspi_cs              ),
    .cio_csb_en_o     ( o_qspi_cs_oe           ),
    .cio_sd_o         ( o_qspi_sd              ),
    .cio_sd_en_o      ( o_qspi_sd_oe           ),
    .cio_sd_i         ( i_qspi_sd              ),
    .intr_error_o     ( qspi0_irq_error        ),
    .intr_spi_event_o ( qspi0_irq_spi_event    )
);

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
        .N_SOURCE  ( NIrqSources ),
        .N_TARGET  ( NIrqTargets ),
        .MAX_PRIO  ( 1           ),
        .reg_req_t ( reg_req_t   ),
        .reg_rsp_t ( reg_rsp_t   )
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
// CLINT: reg demux -> reg_bus -> ACLINT
// ============================================================

reg_req_t clint_reg_req;
always_comb begin
    clint_reg_req      = reg_dev_req[ClintPort];
    clint_reg_req.addr = reg_dev_req[ClintPort].addr & (ClintSize - 1);
end

// The tick generator comes out of reset at a 1:1 ratio
aclint #(
    .NumHarts      ( 1         ),
    .DefaultTarget ( 1         ),
    .DefaultSource ( 1         ),
    .reg_req_t     ( reg_req_t ),
    .reg_rsp_t     ( reg_rsp_t )
) clint (
    .clk_i      ( i_clk                  ),
    .rst_ni     ( soc_rstn               ),
    .reg_req_i  ( clint_reg_req          ),
    .reg_rsp_o  ( reg_dev_rsp[ClintPort] ),
    .mtip_o     ( mtip                   ),
    .msip_o     ( msip                   ),
    .ssip_set_o (                        ),
    .mtime_o    ( mtime                  )
);

endmodule

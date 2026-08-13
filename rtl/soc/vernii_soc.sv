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
//
// Emil Popović <mail@emilpopovic.me>
// Matej Jurasić <matej.jurasic@cappig.dev>

`include "axi/assign.svh"
`include "apb/typedef.svh"

module vernii_soc import vernii_pkg::*, axi_pkg::xbar_rule_32_t, dm::hartinfo_t; #(
    parameter int unsigned OcmBase          = 32'h0000_0000,
    parameter int unsigned OcmSize          = 32'h0000_2000,
    parameter int unsigned ExtBase          = 32'h8000_0000,
    parameter int unsigned ExtSize          = 32'h0100_0000,
    parameter int unsigned LineBytes        = 32,
    parameter int unsigned Ways             = 4,
    parameter bit          SramTags         = 1'b1,
    parameter int unsigned ItlbEntries      = 2,
    parameter int unsigned DtlbEntries      = 4,
    parameter bit          FineTlbFlush     = 0,
    parameter bit          EnforcePmp       = 0,
    parameter bit          EnableExtM       = 1,
    parameter bit          EnableExtA       = 1,
    parameter bit          EnableFastMul    = 0,
    parameter bit          ZsblRomEnable    = 1'b1,
    parameter int unsigned ZsblRomWords     = vernii_zsbl_rom_pkg::ZSBL_PROG_WORDS,
    parameter logic [31:0] ZsblRomProg [ZsblRomWords] = vernii_zsbl_rom_pkg::ZSBL_PROG,
    parameter logic [31:0] ZsblBaseAddr     = 32'h0020_0000,
    parameter int unsigned NumStraps        = 8,
    parameter int unsigned NumExtRegSlv     = 1,
    parameter bit          HaltOnEnd        = 0,
    parameter int unsigned NumExtIrq        = 2,
    parameter int unsigned NumGpioAIrq      = 8,
    parameter axi_pkg::xbar_rule_32_t [NumExtRegSlv-1:0] ExtRegSlvRules = '{default: '0},
    parameter type axi_req_t = vernii_axi_req_t,
    parameter type axi_rsp_t = vernii_axi_resp_t,
    parameter type reg_req_t = vernii_reg_req_t,
    parameter type reg_rsp_t = vernii_reg_rsp_t
) (
    input  logic  clk_i,
    input  logic  rst_ni,

    input  logic  test_mode_i,

    output logic  por_rst_no,
    output logic  soc_rst_no,

    output logic  end_o,

    // External memory
    output axi_req_t axi_mem_req_o,
    input  axi_rsp_t axi_mem_rsp_i,

    // External register slaves
    output reg_req_t [NumExtRegSlv-1:0] reg_ext_req_o,
    input  reg_rsp_t [NumExtRegSlv-1:0] reg_ext_rsp_i,

    // Straps
    input  logic [NumStraps-1:0] strap_i,

    // UART
    input  logic  uart0_rx_i,
    output logic  uart0_tx_o,

    // JTAG
    input  logic jtag_tck_i,
    input  logic jtag_tms_i,
    input  logic jtag_trst_ni,
    input  logic jtag_tdi_i,
    output logic jtag_tdo_o,
    output logic jtag_tdo_oe_o,

    // QSPI0
    output logic       qspi0_sck_o,
    output logic       qspi0_sck_oe_o,
    output logic [2:0] qspi0_cs_o,
    output logic [2:0] qspi0_cs_oe_o,
    output logic [3:0] qspi0_sd_o,
    output logic [3:0] qspi0_sd_oe_o,
    input  logic [3:0] qspi0_sd_i,

    // External interrupts
    // Single unused bit when NumExtIrq is 0
    input  logic [(NumExtIrq > 0 ? NumExtIrq : 1)-1:0] ext_irq_i,

    // GPIO Port A
    input  logic [31:0] gpio_a_i,
    output logic [31:0] gpio_a_o,
    output logic [31:0] gpio_a_oe_o
);

logic por_rstn;  // power-on reset synchronizer
logic soc_rstn, soc_rstn_async;

`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
rstgen i_rstgen_por (
    .clk_i,
    .rst_ni,
    .test_mode_i,
    .rst_no  ( por_rstn    ),
    .init_no (             )
);
`pragma diagnostic pop

`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
rstgen i_rstgen_soc (
    .clk_i,
    .rst_ni  ( soc_rstn_async ),
    .test_mode_i,
    .rst_no  ( soc_rstn       ),
    .init_no (                )
);
`pragma diagnostic pop

// ============================================================
// CPU subsystem
// ============================================================

friscv_mem_if cpu_if ();

logic [63:0] mtime;
logic        msip, mtip, meip, seip;

localparam logic [31:0] DmBaseAddr   = 32'h0010_0000;
localparam logic [31:0] DmSize       = 32'h0000_1000;

logic ndmreset;   // non-debug-module reset request from the DM
logic debug_req;  // async debug request to the hart

// In test mode the reset synchronizer above is bypassed, which would put dmcontrol.ndmreset
// (a scan-chain flop) on a combinational path to the async reset of the whole SoC.
assign soc_rstn_async = por_rstn & (test_mode_i | ~ndmreset);

assign por_rst_no = por_rstn;
assign soc_rst_no = soc_rstn;

friscv_cpu_subsystem_core #(
    .RamBase            ( ExtBase          ),
    .ZsblRomEnable      ( ZsblRomEnable    ),
    .ZsblRomWords       ( ZsblRomWords     ),
    .ZsblRomProg        ( ZsblRomProg      ),
    .ZsblRomBase        ( ZsblBaseAddr     ),
    .DmBase             ( DmBaseAddr       ),
    .HaltOnEndAddress   ( HaltOnEnd        ),
    .ItlbEntries        ( ItlbEntries      ),
    .DtlbEntries        ( DtlbEntries      ),
    .EnableMul          ( EnableExtM       ),
    .EnableDiv          ( EnableExtM       ),
    .EnableFastMul      ( EnableFastMul    ),
    .EnableExtensionA   ( EnableExtA       ),
    .EnforcePmp         ( EnforcePmp       ),
    .EnableFineTlbFlush ( FineTlbFlush     )
) cpu_subsystem (
    .i_clk     ( clk_i     ),
    .i_rstn    ( soc_rstn  ),
    .o_end     ( end_o     ),
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

if (OcmBase < DmBaseAddr + DmSize &&
    DmBaseAddr < OcmBase + OcmSize) begin : gen_chk_sram_dm
    $error("the OCM window (%08x + %08x) covers the debug module at %08x",
           OcmBase, OcmSize, DmBaseAddr);
end
localparam int unsigned ZsblRomWindow = ZsblRomEnable ? (1 << $clog2(ZsblRomWords * 4)) : 0;

// Check that a large OCM does not overlap with the ZSBL region
if (ZsblRomWindow > 0 && OcmBase < ZsblBaseAddr + ZsblRomWindow &&
    ZsblBaseAddr < OcmBase + OcmSize) begin : gen_chk_sram_zsbl
    $fatal(1, "the OCM window (%08x + %08x) covers the ZSBL ROM window (%08x + %08x)",
           OcmBase, OcmSize, ZsblBaseAddr, ZsblRomWindow);
end

logic [Ways-1:0] llcsel;
logic            crpsel;
logic            llcinv;

friscv_mem_if dm_if ();
friscv_mem_if ext_if ();
friscv_mem_if soc_if ();

friscv_mem_hub #(
    .ExtBase   ( ExtBase   ),
    .ExtSize   ( ExtSize   ),
    .OcmBase   ( OcmBase   ),
    .OcmSize   ( OcmSize   ),
    .LineBytes ( LineBytes ),
    .Ways      ( Ways      ),
    .SramTags  ( SramTags  )
) friscv_mem_hub (
    .clk_i,
    .rst_ni   ( soc_rstn ),
    .s_cpu_if ( cpu_if   ),
    .s_dm_if  ( dm_if    ),
    .m_ext_if ( ext_if   ),
    .m_sys_if ( soc_if   ),
    .llcsel_i ( llcsel   ),
    .crpsel_i ( crpsel   ),
    .llcinv_i ( llcinv   )
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
    .RegisterReq ( 1 )
) soc_to_mem (
    .clk_i,
    .rst_ni      ( soc_rstn   ),
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
    .s_mem       ( soc_if     )
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
    .clk_i     ( clk_i        ),
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

localparam xbar_rule_32_t [NoIntRegRules-1:0] IntRegRules = '{
    '{ idx: DmPort,    start_addr: DmBaseAddr,    end_addr: DmBaseAddr + DmSize },
    '{ idx: ClintPort, start_addr: ClintBaseAddr, end_addr: ClintBaseAddr + ClintSize },
    '{ idx: PlicPort,  start_addr: 32'h0C00_0000, end_addr: 32'h0C20_2000 },
    '{ idx: Uart0Port, start_addr: 32'h1000_0000, end_addr: 32'h1000_1000 },
    '{ idx: GpioAPort, start_addr: 32'h2000_0000, end_addr: 32'h2000_0040 },
    '{ idx: ScbPort,   start_addr: 32'h4000_0000, end_addr: 32'h4000_1000 },
    '{ idx: Qspi0Port, start_addr: 32'h6000_0000, end_addr: 32'h6000_1000 }
};

function automatic bit rule_populated(input xbar_rule_32_t rule);
    rule_populated = rule.start_addr != rule.end_addr;
endfunction

function automatic logic [31:0] rule_end(input xbar_rule_32_t rule);
    rule_end = (rule.end_addr == '0) ? '1 : rule.end_addr;
endfunction

function automatic int unsigned count_ext_rules();
    count_ext_rules = 0;
    for (int unsigned i = 0; i < NumExtRegSlv; i++) begin
        if (rule_populated(ExtRegSlvRules[i])) count_ext_rules++;
    end
endfunction

localparam int unsigned NoExtRegRules = count_ext_rules();
localparam int unsigned NoRegRules    = NoIntRegRules + NoExtRegRules;

function automatic xbar_rule_32_t [NoRegRules-1:0] gen_reg_rules();
    xbar_rule_32_t rule;
    int unsigned   n;

    gen_reg_rules = '0;
    n             = 0;

    // External rules go in first, internal take priority in case of overlap
    for (int unsigned i = 0; i < NumExtRegSlv; i++) begin
        if (rule_populated(ExtRegSlvRules[i])) begin
            rule     = ExtRegSlvRules[i];
            rule.idx = rule.idx + NumIntRegPorts;
            gen_reg_rules[n] = rule;
            n++;
        end
    end

    for (int unsigned i = 0; i < NoIntRegRules; i++) begin
        gen_reg_rules[NoExtRegRules + i] = IntRegRules[i];
    end
endfunction

localparam xbar_rule_32_t [NoRegRules-1:0] RegAddrMap = gen_reg_rules();

// Check that the external reg slave rules are valid and do not overlap internal rules
for (genvar e = 0; e < NumExtRegSlv; e++) begin : gen_chk_ext_rule
    // Check if the external slave index is in range
    if (rule_populated(ExtRegSlvRules[e]) && ExtRegSlvRules[e].idx >= NumExtRegSlv) begin : gen_chk_idx
        $fatal(1, "ExtRegSlvRules[%0d].idx (%0d) is not a valid external slave index (0..%0d)",
               e, ExtRegSlvRules[e].idx, NumExtRegSlv - 1);
    end
    // Check that end_addr is not below start_addr
    if (rule_populated(ExtRegSlvRules[e]) && rule_end(ExtRegSlvRules[e]) < ExtRegSlvRules[e].start_addr) begin : gen_chk_range
        $fatal(1, "ExtRegSlvRules[%0d] ends (%08x) below where it starts (%08x)",
               e, ExtRegSlvRules[e].end_addr, ExtRegSlvRules[e].start_addr);
    end
    // Check that the external rule does not overlap any internal rule
    for (genvar n = 0; n < NoIntRegRules; n++) begin : gen_chk_int_overlap
        if (rule_populated(ExtRegSlvRules[e]) &&
            ExtRegSlvRules[e].start_addr < rule_end(IntRegRules[n]) &&
            IntRegRules[n].start_addr < rule_end(ExtRegSlvRules[e])) begin : gen_chk_overlap
            $fatal(1, "ExtRegSlvRules[%0d] (%08x..%08x) overlaps the internal region %08x..%08x",
                   e, ExtRegSlvRules[e].start_addr, rule_end(ExtRegSlvRules[e]),
                   IntRegRules[n].start_addr, rule_end(IntRegRules[n]));
        end
    end
end

logic [RegPortWidth-1:0] reg_select;

`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
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
`pragma diagnostic pop

`REG_TIE_OFF(ErrPort)

reg_demux #(
    .NoPorts ( NoRegPorts ),
    .req_t   ( reg_req_t  ),
    .rsp_t   ( reg_rsp_t  )
) reg_demux (
    .clk_i       ( clk_i        ),
    .rst_ni      ( soc_rstn     ),
    .in_select_i ( reg_select   ),
    .in_req_i    ( regs_reg_req ),
    .in_rsp_o    ( regs_reg_rsp ),
    .out_req_o   ( reg_dev_req  ),
    .out_rsp_i   ( reg_dev_rsp  )
);

for (genvar i = 0; i < NumExtRegSlv; i++) begin : gen_ext_reg
    assign reg_ext_req_o[i]                    = reg_dev_req[NumIntRegPorts + i];
    assign reg_dev_rsp[NumIntRegPorts + i]     = reg_ext_rsp_i[i];
end

// ============================================================
// System Control Block
// ============================================================

logic ext_mem_en;

vernii_scb #(
    .NumPads    ( NumStraps ),
    .reg_req_t  ( reg_req_t ),
    .reg_rsp_t  ( reg_rsp_t ),
    .OcmLlcWays ( Ways      )
) scb (
    .clk_i,
    .rst_ni    ( soc_rstn             ),
    .reg_req_i ( reg_dev_req[ScbPort] ),
    .reg_rsp_o ( reg_dev_rsp[ScbPort] ),
    .strap_i,
    .hb_en_o   ( ext_mem_en           ),
    .llcsel_o  ( llcsel               ),
    .crpsel_o  ( crpsel               ),
    .llcinv_o  ( llcinv               )
);

// ============================================================
// External memory interface
// ============================================================

friscv_mem_if ext_guarded_if ();

friscv_guard ext_guard (
    .en_i  ( ext_mem_en     ),
    .s_mem ( ext_if         ),
    .m_mem ( ext_guarded_if )
);

AXI_BUS #(
    .AXI_ADDR_WIDTH ( AddrWidth    ),
    .AXI_DATA_WIDTH ( DataWidth    ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
) mem_axi ();

friscv_to_axi4_full_intf #(
    .BurstLen     ( LineBytes / StrbWidth ),
    .AxiIdWidth   ( AxiIdWidth            ),
    .AxiUserWidth ( AxiUserWidth          )
) m_mem (
    .clk_i,
    .rst_ni ( soc_rstn       ),
    .s_mem  ( ext_guarded_if ),
    .m_axi  ( mem_axi        )
);

`AXI_ASSIGN_TO_REQ(axi_mem_req_o, mem_axi)
`AXI_ASSIGN_FROM_RESP(mem_axi, axi_mem_rsp_i)

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

`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
dm_top #(
    .NrHarts       ( 1          ),
    .BusWidth      ( 32         ),
    .DmBaseAddress ( DmBaseAddr )
) dm (
    // Keep the DM and DTM on the power-on reset so debug survives an ndmreset
    .clk_i,
    .rst_ni               ( por_rstn       ),

    .next_dm_addr_i       ( '0             ),  // No next DM in the chain
    .testmode_i           ( test_mode_i    ),
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
`pragma diagnostic pop

logic jtag_trstn, jtag_trstn_async;

assign jtag_trstn_async = rst_ni & jtag_trst_ni;

`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
rstgen i_rstgen_tck (
    .clk_i       ( jtag_tck_i       ),
    .rst_ni      ( jtag_trstn_async ),
    .test_mode_i ( test_mode_i      ),
    .rst_no      ( jtag_trstn       ),
    .init_no     (                  )
);
`pragma diagnostic pop

dmi_jtag #(
    .IdcodeValue ( 32'h00000DB3 )
) dmi (
    .clk_i,
    .rst_ni           ( por_rstn       ),
    .testmode_i       ( test_mode_i    ),

    .dmi_rst_no       ( dmi_rst        ),
    .dmi_req_o        ( dmi_req        ),
    .dmi_req_valid_o  ( dmi_req_valid  ),
    .dmi_req_ready_i  ( dmi_req_ready  ),

    .dmi_resp_i       ( dmi_resp       ),
    .dmi_resp_ready_o ( dmi_resp_ready ),
    .dmi_resp_valid_i ( dmi_resp_valid ),

    .tck_i            ( jtag_tck_i     ),
    .tms_i            ( jtag_tms_i     ),
    .trst_ni          ( jtag_trstn     ),
    .td_i             ( jtag_tdi_i     ),
    .td_o             ( jtag_tdo_o     ),
    .tdo_oe_o         ( jtag_tdo_oe_o  )
);

reg_to_mem #(
    .AW    ( 32        ),
    .DW    ( 32        ),
    .req_t ( reg_req_t ),
    .rsp_t ( reg_rsp_t )
) dm_reg_to_mem (
    .clk_i,
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
always_ff @(posedge clk_i or negedge soc_rstn) begin
    if (!soc_rstn) dbg_slv_rvalid <= 1'b0;
    else           dbg_slv_rvalid <= dbg_slv_req & ~dbg_slv_we;
end

// DM SBA master port: dm master -> bridge -> mem hub DM port
mem_to_friscv dm_sba_mem (
    .clk_i,
    .rst_ni      ( soc_rstn      ),
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
    .m_mem       ( dm_if         )
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
    .clk_i,
    .rst_ni    ( soc_rstn               ),
    .reg_req_i ( reg_dev_req[Uart0Port] ),
    .reg_rsp_o ( reg_dev_rsp[Uart0Port] ),
    .apb_req_o ( uart0_apb_req          ),
    .apb_rsp_i ( uart0_apb_rsp          )
);

logic uart0_irq;

// APB -> 16550 UART
`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
apb_uart_wrap #(
    .apb_req_t ( apb_req_t  ),
    .apb_rsp_t ( apb_resp_t )
) uart0 (
    .clk_i,
    .rst_ni    ( soc_rstn      ),
    .apb_req_i ( uart0_apb_req ),
    .apb_rsp_o ( uart0_apb_rsp ),
    .intr_o    ( uart0_irq     ),
    .sin_i     ( uart0_rx_i    ),
    .sout_o    ( uart0_tx_o    ),
    .cts_ni    ( 1'b0          ),
    .dsr_ni    ( 1'b0          ),
    .dcd_ni    ( 1'b0          ),
    .rin_ni    ( 1'b0          ),
    .out1_no   (               ),
    .out2_no   (               ),
    .rts_no    (               ),
    .dtr_no    (               )
);
`pragma diagnostic pop

// ============================================================
// GPIO Port A
// ============================================================

logic [31:0] gpio_a_irq;

gpio #(
    .reg_req_t   ( reg_req_t ),
    .reg_rsp_t   ( reg_rsp_t ),
    .GpioAsyncOn ( 1         )
) gpio_a (
    .clk_i,
    .rst_ni        ( soc_rstn               ),
    .reg_req_i     ( reg_dev_req[GpioAPort] ),
    .reg_rsp_o     ( reg_dev_rsp[GpioAPort] ),
    .intr_gpio_o   ( gpio_a_irq             ),
    .cio_gpio_i    ( gpio_a_i               ),
    .cio_gpio_o    ( gpio_a_o               ),
    .cio_gpio_en_o ( gpio_a_oe_o            )
);

// ============================================================
// QSPI0
// ============================================================

logic qspi0_irq_error, qspi0_irq_spi_event;

spi_host #(
    .reg_req_t ( reg_req_t ),
    .reg_rsp_t ( reg_rsp_t )
) qspi0 (
    .clk_i,
    .rst_ni           ( soc_rstn               ),
    .reg_req_i        ( reg_dev_req[Qspi0Port] ),
    .reg_rsp_o        ( reg_dev_rsp[Qspi0Port] ),
    .cio_sck_o        ( qspi0_sck_o            ),
    .cio_sck_en_o     ( qspi0_sck_oe_o         ),
    .cio_csb_o        ( qspi0_cs_o             ),
    .cio_csb_en_o     ( qspi0_cs_oe_o          ),
    .cio_sd_o         ( qspi0_sd_o             ),
    .cio_sd_en_o      ( qspi0_sd_oe_o          ),
    .cio_sd_i         ( qspi0_sd_i             ),
    .intr_error_o     ( qspi0_irq_error        ),
    .intr_spi_event_o ( qspi0_irq_spi_event    )
);

// ============================================================
// PLIC
// ============================================================

localparam int unsigned NumUart0Irq = 1;
localparam int unsigned NumQspi0Irq = 2;

localparam int unsigned Uart0IrqBase = 0;
localparam int unsigned Qspi0IrqBase = Uart0IrqBase + NumUart0Irq;
localparam int unsigned GpioAIrqBase = Qspi0IrqBase + NumQspi0Irq;
localparam int unsigned ExtIrqBase   = GpioAIrqBase + NumGpioAIrq;

// Sources claimed by the allocation above
localparam int unsigned NIrqUsed = ExtIrqBase + NumExtIrq;

// The PLIC width is fixed to not have to regenerate the address map
localparam int unsigned NIrqSources = 31;

if (NumGpioAIrq > 32) begin : gen_chk_gpio_a_irq
    $error("NumGpioAIrq (%0d) more than the 32 GPIO port A pins", NumGpioAIrq);
end
if (NIrqUsed > NIrqSources) begin : gen_chk_irq_budget
    $error("the interrupt allocation needs %0d sources but the PLIC has %0d, reduce NumGpioAIrq (%0d) or NumExtIrq (%0d)",
           NIrqUsed, NIrqSources, NumGpioAIrq, NumExtIrq);
end

logic [NIrqSources-1:0] plic_irq_sources;

assign plic_irq_sources[Uart0IrqBase]                = uart0_irq;
assign plic_irq_sources[Qspi0IrqBase +: NumQspi0Irq] = {qspi0_irq_spi_event, qspi0_irq_error};

if (NumGpioAIrq > 0) begin : gen_gpio_a_irq
    assign plic_irq_sources[GpioAIrqBase +: NumGpioAIrq] = gpio_a_irq[NumGpioAIrq-1:0];
end

if (NumExtIrq > 0) begin : gen_ext_irq
    logic [NumExtIrq-1:0] ext_irq_sync;

    for (genvar i = 0; i < NumExtIrq; i++) begin : gen_ext_irq_sync
        tc_sync #(
            .Stages     ( 2    ),
            .ResetValue ( 1'b0 )
        ) sync_ext_irq (
            .clk_i,
            .rst_ni   ( soc_rstn        ),
            .serial_i ( ext_irq_i[i]    ),
            .serial_o ( ext_irq_sync[i] )
        );
    end

    assign plic_irq_sources[ExtIrqBase +: NumExtIrq] = ext_irq_sync;
end

if (NIrqUsed < NIrqSources) begin : gen_irq_unused
    assign plic_irq_sources[NIrqSources-1:NIrqUsed] = '0;
end

// Two targets, context 0 is hart 0 M-mode (MEIP), context 1 is hart 0 S-mode (SEIP)
localparam int unsigned NIrqTargets = 2;
logic [NIrqTargets-1:0] plic_irq_targets;
assign meip = plic_irq_targets[0];
assign seip = plic_irq_targets[1];

plic_top #(
    .N_SOURCE  ( NIrqSources ),
    .N_TARGET  ( NIrqTargets ),
    .MAX_PRIO  ( 1           ),
    .reg_req_t ( reg_req_t   ),
    .reg_rsp_t ( reg_rsp_t   )
) plic (
    .clk_i,
    .rst_ni        ( soc_rstn              ),
    .req_i         ( reg_dev_req[PlicPort] ),
    .resp_o        ( reg_dev_rsp[PlicPort] ),
    .le_i          ( '0                    ),  // All level-held
    .irq_sources_i ( plic_irq_sources      ),
    .eip_targets_o ( plic_irq_targets      )
);

// ============================================================
// CLINT: reg demux -> reg_bus -> ACLINT
// ============================================================

reg_req_t clint_reg_req;
always_comb begin
    clint_reg_req      = reg_dev_req[ClintPort];
    clint_reg_req.addr = reg_dev_req[ClintPort].addr & (ClintSize - 1);
end

// The tick generator comes out of reset at a 1:1 ratio
`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
aclint #(
    .NumHarts      ( 1         ),
    .DefaultTarget ( 1         ),
    .DefaultSource ( 1         ),
    .reg_req_t     ( reg_req_t ),
    .reg_rsp_t     ( reg_rsp_t )
) clint (
    .clk_i,
    .rst_ni     ( soc_rstn               ),
    .reg_req_i  ( clint_reg_req          ),
    .reg_rsp_o  ( reg_dev_rsp[ClintPort] ),
    .mtip_o     ( mtip                   ),
    .msip_o     ( msip                   ),
    .ssip_set_o (                        ),
    .mtime_o    ( mtime                  )
);
`pragma diagnostic pop

endmodule

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

`include "apb/typedef.svh"

module vernii_soc import vernii_pkg::*, axi_pkg::xbar_rule_32_t, dm::hartinfo_t,
                        friscv_mem_pkg::friscv_mem_req_t, friscv_mem_pkg::friscv_mem_rsp_t,
                        friscv_mem_pkg::MEM_REQ_IDLE; #(
    parameter int unsigned OcmBase          = 32'h0000_0000,
    parameter int unsigned OcmSize          = 32'h0000_2000,
    parameter int unsigned ExtBase          = 32'h8000_0000,
    parameter int unsigned ExtSize          = 32'h0100_0000,
    parameter int unsigned CachedBase       = ExtBase,
    parameter int unsigned CachedSize       = ExtSize,
    parameter int unsigned LineBytes        = 32,
    parameter int unsigned Ways             = 4,
    parameter bit          SramTags         = 1'b1,
    parameter int unsigned ItlbEntries      = 2,
    parameter int unsigned DtlbEntries      = 4,
    parameter bit          FineTlbFlush     = 0,
    parameter bit          EnforcePmp       = 0,
    parameter bit          EnableIsaE       = 0,
    parameter bit          EnableIsaM       = 1,
    parameter bit          EnableIsaA       = 1,
    parameter bit          EnableFastMul    = 0,
    parameter bit          ZsblRomEnable    = 1'b1,
    parameter int unsigned ZsblRomWords     = vernii_zsbl_rom_pkg::ZSBL_PROG_WORDS,
    parameter logic [31:0] ZsblRomProg [ZsblRomWords] = vernii_zsbl_rom_pkg::ZSBL_PROG,
    parameter int unsigned NumStraps        = 8,
    parameter int unsigned NumMRegRules     = 1,
    parameter bit          HaltOnEnd        = 0,
    parameter int unsigned NumExtIrq        = 2,
    parameter int unsigned NumGpioAIrq      = 8,
    parameter bit          EnableSAxiGp     = 1'b0,
    parameter int unsigned NumSAxiGpRules   = 1,

    parameter type axi_lite_req_t = vernii_axi_lite_req_t,
    parameter type axi_lite_rsp_t = vernii_axi_lite_resp_t,
    parameter type axi_req_t      = vernii_axi_req_t,
    parameter type axi_rsp_t      = vernii_axi_resp_t,
    parameter type reg_req_t      = vernii_reg_req_t,
    parameter type reg_rsp_t      = vernii_reg_rsp_t,

    parameter axi_pkg::xbar_rule_32_t [NumMRegRules-1:0]   MRegRules   = '{default: '0},
    parameter axi_pkg::xbar_rule_32_t [NumSAxiGpRules-1:0] SAxiGpRules = '{default: '0}
) (
    input  logic  clk_i,
    input  logic  rst_ni,

    input  logic  test_mode_i,

    output logic  por_rst_no,
    output logic  soc_rst_no,

    output logic  end_o,

    // External general-purpose subordinate port
    input  axi_lite_req_t s_axi_gp_req_i,
    output axi_lite_rsp_t s_axi_gp_rsp_o,

    // External high-performance manager port
    output axi_req_t m_axi_hp_req_o,
    input  axi_rsp_t m_axi_hp_rsp_i,

    // External register manager port
    output reg_req_t [NumMRegRules-1:0] m_reg_req_o,
    input  reg_rsp_t [NumMRegRules-1:0] m_reg_rsp_i,

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

/////////////////
// Address map //
/////////////////

//   0x0000_0000  OCM              OcmSize
//   0x0200_0000  clint            128 KiB
//   0x0300_0000  scb
//   0x0301_0000  uart0
//   0x0302_0000  qspi0
//   0x0303_0000  gpio port a
//   0x0304_0000  zsbl rom
//   0x0305_0000  debug module
//   0x0c00_0000  plic             2 MiB
//   0x8000_0000  external memory  ExtSize

// MSWI + MTIMER + tick generator config + SSWI, the whole ACLINT map
localparam logic [31:0] ClintBaseAddr = 32'h0200_0000;
localparam logic [31:0] ClintSize     = 32'h0002_0000;

localparam logic [31:0] PlicBaseAddr = 32'h0C00_0000;
localparam logic [31:0] PlicSize     = 32'h0020_2000;

// Decode 4 KiB each, 64 KiB apart
localparam logic [31:0] PeriphSize    = 32'h0000_1000;
localparam logic [31:0] ScbBaseAddr   = 32'h0300_0000;
localparam logic [31:0] Uart0BaseAddr = 32'h0301_0000;
localparam logic [31:0] Qspi0BaseAddr = 32'h0302_0000;
localparam logic [31:0] GpioABaseAddr = 32'h0303_0000;
localparam logic [31:0] ZsblBaseAddr  = 32'h0304_0000;
localparam logic [31:0] DmBaseAddr    = 32'h0305_0000;
localparam logic [31:0] DmSize        = PeriphSize;

// Contents rounded up to a power of two, the rest of the slot decodes as error
localparam int unsigned ZsblRomWindow = ZsblRomEnable ? (1 << $clog2(ZsblRomWords * 4)) : 0;

logic por_rst_n;  // power-on reset synchronizer
logic soc_rst_n, soc_rst_n_async;

`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
rstgen i_rstgen_por (
    .clk_i,
    .rst_ni,
    .test_mode_i,
    .rst_no  ( por_rst_n ),
    .init_no (           )
);
`pragma diagnostic pop

`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
rstgen i_rstgen_soc (
    .clk_i,
    .rst_ni  ( soc_rst_n_async ),
    .test_mode_i,
    .rst_no  ( soc_rst_n       ),
    .init_no (                 )
);
`pragma diagnostic pop

//////////////////
// FRISC-V Core //
//////////////////

friscv_mem_req_t cpu_req;
friscv_mem_rsp_t cpu_rsp;

logic [63:0] mtime;
logic        msip, mtip, meip, seip;

logic ndmreset;   // non-debug-module reset request from the DM
logic debug_req;  // async debug request to the hart

// In test mode the reset synchronizer above is bypassed, which would put dmcontrol.ndmreset
// (a scan-chain flop) on a combinational path to the async reset of the whole SoC.
assign soc_rst_n_async = por_rst_n & (test_mode_i | ~ndmreset);

assign por_rst_no = por_rst_n;
assign soc_rst_no = soc_rst_n;

// The zsbl rom is a reg-bus peripheral, the core just boots at its base
localparam int unsigned ResetVec = ZsblRomEnable ? ZsblBaseAddr : ExtBase;

friscv #(
    .ResetVec           ( ResetVec         ),
    .DmBase             ( DmBaseAddr       ),
    .HaltOnEndAddress   ( HaltOnEnd        ),
    .ItlbEntries        ( ItlbEntries      ),
    .DtlbEntries        ( DtlbEntries      ),
    .EnableIsaE         ( EnableIsaE       ),
    .EnableIsaM         ( EnableIsaM       ),
    .EnableFastMul      ( EnableFastMul    ),
    .EnableIsaA         ( EnableIsaA       ),
    .EnforcePmp         ( EnforcePmp       ),
    .EnableFineTlbFlush ( FineTlbFlush     )
) i_cpu (
    .clk_i,
    .rst_ni    ( soc_rst_n ),
    .end_o     ( end_o     ),
    .msip_i    ( msip      ),
    .mtip_i    ( mtip      ),
    .meip_i    ( meip      ),
    .seip_i    ( seip      ),
    .mtime_i   ( mtime     ),
    .mem_req_o ( cpu_req   ),
    .mem_rsp_i ( cpu_rsp   ),
    .dbg_req_i ( debug_req )
);

//////////////////////////
// Address Rule Helpers //
//////////////////////////

function automatic logic rule_populated(input xbar_rule_32_t rule);
    return rule.start_addr != rule.end_addr;
endfunction

function automatic logic [31:0] rule_end(input xbar_rule_32_t rule);
    return (rule.end_addr == '0) ? '1 : rule.end_addr;
endfunction

//////////////////////////////////////////////////////////////
// External GP subordinate port -> FRISC-V memory interface //
//////////////////////////////////////////////////////////////

// axi_lite -> axi -> mem -> friscv_mem_if
// Done this way to avoid having to implement any new protocol converter.

localparam int unsigned SAxiIdWidth = AxiIdWidth;

localparam int unsigned SAxiGpBusPort = 0;
localparam int unsigned SAxiGpErrPort = 1;
localparam int unsigned SAxiGpPorts   = 2;

vernii_axi_req_t  s_axi_gp_req;
vernii_axi_resp_t s_axi_gp_rsp;

vernii_axi_req_t  [SAxiGpPorts-1:0] s_axi_gp_dev_req;
vernii_axi_resp_t [SAxiGpPorts-1:0] s_axi_gp_dev_rsp;

friscv_mem_req_t s_gp_mem_req;
friscv_mem_rsp_t s_gp_mem_rsp;

// Check that each SAxiGpRule has end_addr >= start_addr
for (genvar g = 0; g < NumSAxiGpRules; g++) begin : gen_chk_gp_rule
    if (rule_populated(SAxiGpRules[g]) &&
        rule_end(SAxiGpRules[g]) < SAxiGpRules[g].start_addr) begin : gen_chk_range
        $fatal(1, "SAxiGpRules[%0d] ends (%08x) below where it starts (%08x)",
               g, SAxiGpRules[g].end_addr, SAxiGpRules[g].start_addr);
    end
end

// An access is allowed on AXI GP if it matches any populated SAxiGpRule
function automatic logic s_axi_gp_allowed(input addr_t addr);
    logic result = 1'b0;
    for (int unsigned i = 0; i < NumSAxiGpRules; i++) begin
        if (rule_populated(SAxiGpRules[i]) &&
            addr >= SAxiGpRules[i].start_addr && addr < rule_end(SAxiGpRules[i])) begin
            result = 1'b1;
        end
    end
    return result;
endfunction

// axi_lite -> axi
axi_lite_to_axi #(
    .AxiDataWidth ( DataWidth         ),
    .req_lite_t   ( axi_lite_req_t    ),
    .resp_lite_t  ( axi_lite_rsp_t    ),
    .axi_req_t    ( vernii_axi_req_t  ),
    .axi_resp_t   ( vernii_axi_resp_t )
) i_s_axi_lite_to_axi (
    .slv_req_lite_i  ( s_axi_gp_req_i ),
    .slv_resp_lite_o ( s_axi_gp_rsp_o ),
    .slv_aw_cache_i  ( '0             ),
    .slv_ar_cache_i  ( '0             ),
    .mst_req_o       ( s_axi_gp_req   ),
    .mst_resp_i      ( s_axi_gp_rsp   )
);

logic s_axi_gp_aw_select, s_axi_gp_ar_select;

// Forward the request to the bus (SAxiGpBusPort) if allowed, otherwise to the error port (SAxiGpErrPort)
assign s_axi_gp_aw_select = (EnableSAxiGp && s_axi_gp_allowed(s_axi_gp_req.aw.addr))
                          ? 1'(SAxiGpBusPort) : 1'(SAxiGpErrPort);
assign s_axi_gp_ar_select = (EnableSAxiGp && s_axi_gp_allowed(s_axi_gp_req.ar.addr))
                          ? 1'(SAxiGpBusPort) : 1'(SAxiGpErrPort);

// Demux between the bus and error ports (s_axi_gp -> {bus_port, error_port})
axi_demux_simple #(
    .AxiIdWidth  ( SAxiIdWidth       ),
    .AtopSupport ( 1'b0              ),
    .axi_req_t   ( vernii_axi_req_t  ),
    .axi_resp_t  ( vernii_axi_resp_t ),
    .NoMstPorts  ( SAxiGpPorts       ),
    .AxiLookBits ( SAxiIdWidth       )
) i_s_axi_gp_demux (
    .clk_i,
    .rst_ni          ( soc_rst_n          ),
    .test_i          ( test_mode_i        ),
    .slv_req_i       ( s_axi_gp_req       ),
    .slv_aw_select_i ( s_axi_gp_aw_select ),
    .slv_ar_select_i ( s_axi_gp_ar_select ),
    .slv_resp_o      ( s_axi_gp_rsp       ),
    .mst_reqs_o      ( s_axi_gp_dev_req   ),
    .mst_resps_i     ( s_axi_gp_dev_rsp   )
);

// Error port answering with DECERR if
//  1) SAxiGp is disabled or
//  2) the access is not allowed by any SAxiGpRule
axi_err_slv #(
    .AxiIdWidth ( SAxiIdWidth          ),
    .axi_req_t  ( vernii_axi_req_t     ),
    .axi_resp_t ( vernii_axi_resp_t    ),
    .Resp       ( axi_pkg::RESP_DECERR ),
    .RespWidth  ( DataWidth            ),
    .RespData   ( 32'h0BAD_0BAD        ),
    .ATOPs      ( 1'b0                 )
) i_s_axi_gp_err_slv (
    .clk_i,
    .rst_ni     ( soc_rst_n                       ),
    .test_i     ( test_mode_i                     ),
    .slv_req_i  ( s_axi_gp_dev_req[SAxiGpErrPort] ),
    .slv_resp_o ( s_axi_gp_dev_rsp[SAxiGpErrPort] )
);

if (EnableSAxiGp) begin : gen_axi_gp

    // IF SAxiGp is enabled, generate the bus adapters between AXI and
    // the mem_hub's friscv_mem_if

    logic s_mem_req, s_mem_gnt, s_mem_we, s_mem_rvalid, s_mem_err;
    logic [AddrWidth-1:0] s_mem_addr;
    logic [DataWidth-1:0] s_mem_wdata, s_mem_rdata;
    logic [StrbWidth-1:0] s_mem_strb;

    // axi -> mem
    `pragma diagnostic push
    `pragma diagnostic ignore="-Wempty-output-connection"
    axi_to_detailed_mem #(
        .axi_req_t  ( vernii_axi_req_t  ),
        .axi_resp_t ( vernii_axi_resp_t ),
        .AddrWidth  ( AddrWidth         ),
        .DataWidth  ( DataWidth         ),
        .IdWidth    ( SAxiIdWidth       )
    ) i_s_axi_to_mem (
        .clk_i,
        .rst_ni       ( soc_rst_n                       ),
        .busy_o       ( /* unused */                    ),
        .axi_req_i    ( s_axi_gp_dev_req[SAxiGpBusPort] ),
        .axi_resp_o   ( s_axi_gp_dev_rsp[SAxiGpBusPort] ),
        .mem_req_o    ( s_mem_req                       ),
        .mem_gnt_i    ( s_mem_gnt                       ),
        .mem_addr_o   ( s_mem_addr                      ),
        .mem_wdata_o  ( s_mem_wdata                     ),
        .mem_strb_o   ( s_mem_strb                      ),
        .mem_atop_o   ( /* unused */                    ),
        .mem_lock_o   ( /* unused */                    ),
        .mem_we_o     ( s_mem_we                        ),
        .mem_id_o     ( /* unused */                    ),
        .mem_user_o   ( /* unused */                    ),
        .mem_cache_o  ( /* unused */                    ),
        .mem_prot_o   ( /* unused */                    ),
        .mem_qos_o    ( /* unused */                    ),
        .mem_region_o ( /* unused */                    ),
        .mem_rvalid_i ( s_mem_rvalid                    ),
        .mem_rdata_i  ( s_mem_rdata                     ),
        .mem_err_i    ( s_mem_err                       ),
        .mem_exokay_i ( '0                              )
    );
    `pragma diagnostic pop

    // mem -> friscv_mem_if
    `pragma diagnostic push
    `pragma diagnostic ignore="-Wempty-output-connection"
    mem_to_friscv i_s_mem_to_friscv (
        .clk_i,
        .rst_ni      ( soc_rst_n    ),
        .req_i       ( s_mem_req    ),
        .addr_i      ( s_mem_addr   ),
        .we_i        ( s_mem_we     ),
        .wdata_i     ( s_mem_wdata  ),
        .be_i        ( s_mem_strb   ),
        .gnt_o       ( s_mem_gnt    ),
        .rvalid_o    ( s_mem_rvalid ),
        .err_o       ( s_mem_err    ),
        .other_err_o ( /* unused */ ),
        .rdata_o     ( s_mem_rdata  ),
        .m_req_o     ( s_gp_mem_req ),
        .m_rsp_i     ( s_gp_mem_rsp )
    );
    `pragma diagnostic pop

end else begin : gen_no_axi_gp

    // The bus port of the demux is never selected, so it never sees a request
    assign s_axi_gp_dev_rsp[SAxiGpBusPort] = '0;

    // And the hub never sees a transfer from this port
    assign s_gp_mem_req = MEM_REQ_IDLE;

end

///////////////////////////////////////////////////////
// Memory Hub {cpu, s_axi_gp, dm} -> {soc, m_axi_hp} //
///////////////////////////////////////////////////////

logic [Ways-1:0] llcsel;
logic            crpsel;
logic            llcinv;

// LLC statistics, single-cycle pulses counted by the SCB
logic llc_rd_acc, llc_rd_miss, llc_wr_acc;

friscv_mem_req_t dm_req, ext_req, sys_req;
friscv_mem_rsp_t dm_rsp, ext_rsp, sys_rsp;

// S port A: CPU
// S port B: External GP AXI
// S port DM: Debug module
// M port EXT: External memory
// M port SYS: System peripherals
friscv_mem_hub #(
    .ExtBase    ( ExtBase    ),
    .ExtSize    ( ExtSize    ),
    .CachedBase ( CachedBase ),
    .CachedSize ( CachedSize ),
    .OcmBase    ( OcmBase    ),
    .OcmSize    ( OcmSize    ),
    .LineBytes  ( LineBytes  ),
    .Ways       ( Ways       ),
    .SramTags   ( SramTags   )
) i_mem_hub (
    .clk_i,
    .rst_ni      ( soc_rst_n    ),
    .s_a_req_i   ( cpu_req      ),
    .s_a_rsp_o   ( cpu_rsp      ),
    .s_b_req_i   ( s_gp_mem_req ),
    .s_b_rsp_o   ( s_gp_mem_rsp ),
    .s_dm_req_i  ( dm_req       ),
    .s_dm_rsp_o  ( dm_rsp       ),
    .m_ext_req_o ( ext_req      ),
    .m_ext_rsp_i ( ext_rsp      ),
    .m_sys_req_o ( sys_req      ),
    .m_sys_rsp_i ( sys_rsp      ),
    .rd_acc_o    ( llc_rd_acc   ),
    .rd_miss_o   ( llc_rd_miss  ),
    .wr_acc_o    ( llc_wr_acc   ),
    .llcsel_i    ( llcsel       ),
    .crpsel_i    ( crpsel       ),
    .llcinv_i    ( llcinv       )
);

////////////////////////////////////////////////////////////////////////
// Interconnect: mem_if -> mem -> reg_bus -> reg demux -> peripherals //
////////////////////////////////////////////////////////////////////////

`APB_TYPEDEF_ALL(apb, addr_t, data_t, strb_t)

// mem_if -> mem
logic        soc_req, soc_gnt, soc_we, soc_rvalid, soc_err;
addr_t       soc_addr;
data_t       soc_wdata, soc_rdata;
logic [3:0]  soc_be;

friscv_to_mem #(
    .RegisterReq ( 1 )
) i_soc_to_mem (
    .clk_i,
    .rst_ni      ( soc_rst_n  ),
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
    .s_req_i     ( sys_req    ),
    .s_rsp_o     ( sys_rsp    )
);

// mem -> reg_bus
reg_req_t regs_reg_req;
reg_rsp_t regs_reg_rsp;

mem_to_reg #(
    .AW        ( AddrWidth ),
    .DW        ( DataWidth ),
    .reg_req_t ( reg_req_t ),
    .reg_rsp_t ( reg_rsp_t )
) i_soc_mem_to_reg (
    .clk_i     ( clk_i        ),
    .rst_ni    ( soc_rst_n    ),
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

///////////////
// Reg Demux //
///////////////

localparam int unsigned DmPort    = 0;
localparam int unsigned Uart0Port = 1;
localparam int unsigned ScbPort   = 2;
localparam int unsigned GpioAPort = 3;
localparam int unsigned PlicPort  = 4;
localparam int unsigned Qspi0Port = 5;
localparam int unsigned ClintPort = 6;
localparam int unsigned ZsblPort  = 7;
localparam int unsigned ErrPort   = 8;

localparam int unsigned NoRegPorts   = NumIntRegPorts + NumMRegRules;
localparam int unsigned RegPortWidth = $clog2(NoRegPorts);

reg_req_t [NoRegPorts-1:0] reg_dev_req;
reg_rsp_t [NoRegPorts-1:0] reg_dev_rsp;

`define REG_TIE_OFF(port)                   \
    assign reg_dev_rsp[port].rdata = '0;    \
    assign reg_dev_rsp[port].error = 1'b1;  \
    assign reg_dev_rsp[port].ready = 1'b1;

localparam int unsigned NoIntRegRules = 8;

localparam xbar_rule_32_t [NoIntRegRules-1:0] IntRegRules = '{
    '{ idx: DmPort,    start_addr: DmBaseAddr,    end_addr: DmBaseAddr    + DmSize        },
    '{ idx: ClintPort, start_addr: ClintBaseAddr, end_addr: ClintBaseAddr + ClintSize     },
    '{ idx: PlicPort,  start_addr: PlicBaseAddr,  end_addr: PlicBaseAddr  + PlicSize      },
    '{ idx: ScbPort,   start_addr: ScbBaseAddr,   end_addr: ScbBaseAddr   + PeriphSize    },
    '{ idx: Uart0Port, start_addr: Uart0BaseAddr, end_addr: Uart0BaseAddr + PeriphSize    },
    '{ idx: Qspi0Port, start_addr: Qspi0BaseAddr, end_addr: Qspi0BaseAddr + PeriphSize    },
    '{ idx: GpioAPort, start_addr: GpioABaseAddr, end_addr: GpioABaseAddr + PeriphSize    },
    '{ idx: ZsblPort,  start_addr: ZsblBaseAddr,  end_addr: ZsblBaseAddr  + ZsblRomWindow }
};

// The hub answers for the OCM window before the reg bus sees it, so anything
// the OCM covers is unreachable. An empty rule (a disabled rom) cannot collide.
for (genvar r = 0; r < NoIntRegRules; r++) begin : gen_chk_ocm_int_overlap
    if (rule_populated(IntRegRules[r]) &&
        OcmBase < rule_end(IntRegRules[r]) &&
        IntRegRules[r].start_addr < OcmBase + OcmSize) begin : gen_chk_overlap
        $fatal(1, "the OCM window (%08x + %08x) covers the internal region %08x..%08x",
               OcmBase, OcmSize, IntRegRules[r].start_addr, rule_end(IntRegRules[r]));
    end
end

function automatic int unsigned count_m_reg_rules();
    int unsigned result = 0;
    for (int unsigned i = 0; i < NumMRegRules; i++) begin
        if (rule_populated(MRegRules[i])) result++;
    end
    return result;
endfunction

localparam int unsigned NoMRegRules = count_m_reg_rules();
localparam int unsigned NoRegRules    = NoIntRegRules + NoMRegRules;

function automatic xbar_rule_32_t [NoRegRules-1:0] gen_reg_rules();
    xbar_rule_32_t [NoRegRules-1:0] result;
    xbar_rule_32_t rule;
    int unsigned   n;

    result = '0;
    n      = 0;

    // External rules go in first, internal take priority in case of overlap
    for (int unsigned i = 0; i < NumMRegRules; i++) begin
        if (rule_populated(MRegRules[i])) begin
            rule      = MRegRules[i];
            rule.idx  = rule.idx + NumIntRegPorts;
            result[n] = rule;
            n++;
        end
    end

    for (int unsigned i = 0; i < NoIntRegRules; i++) begin
        result[NoMRegRules + i] = IntRegRules[i];
    end
    return result;
endfunction

localparam xbar_rule_32_t [NoRegRules-1:0] RegAddrMap = gen_reg_rules();

// Check that the manager reg rules are valid and do not overlap internal rules
for (genvar e = 0; e < NumMRegRules; e++) begin : gen_chk_m_reg_rule
    // Check if the manager port index is in range
    if (rule_populated(MRegRules[e]) && MRegRules[e].idx >= NumMRegRules) begin : gen_chk_idx
        $fatal(1, "MRegRules[%0d].idx (%0d) is not a valid manager reg port (0..%0d)",
               e, MRegRules[e].idx, NumMRegRules - 1);
    end
    // Check that end_addr is not below start_addr
    if (rule_populated(MRegRules[e]) && rule_end(MRegRules[e]) < MRegRules[e].start_addr) begin : gen_chk_range
        $fatal(1, "MRegRules[%0d] ends (%08x) below where it starts (%08x)",
               e, MRegRules[e].end_addr, MRegRules[e].start_addr);
    end
    // Check that the external rule does not overlap any internal rule
    for (genvar n = 0; n < NoIntRegRules; n++) begin : gen_chk_int_overlap
        if (rule_populated(MRegRules[e]) &&
            MRegRules[e].start_addr < rule_end(IntRegRules[n]) &&
            IntRegRules[n].start_addr < rule_end(MRegRules[e])) begin : gen_chk_overlap
            $fatal(1, "MRegRules[%0d] (%08x..%08x) overlaps the internal region %08x..%08x",
                   e, MRegRules[e].start_addr, rule_end(MRegRules[e]),
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
) i_reg_decode (
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
) i_reg_demux (
    .clk_i       ( clk_i        ),
    .rst_ni      ( soc_rst_n    ),
    .in_select_i ( reg_select   ),
    .in_req_i    ( regs_reg_req ),
    .in_rsp_o    ( regs_reg_rsp ),
    .out_req_o   ( reg_dev_req  ),
    .out_rsp_i   ( reg_dev_rsp  )
);

for (genvar i = 0; i < NumMRegRules; i++) begin : gen_m_reg
    assign m_reg_req_o[i]                    = reg_dev_req[NumIntRegPorts + i];
    assign reg_dev_rsp[NumIntRegPorts + i]     = m_reg_rsp_i[i];
end

//////////////////////////
// System Control Block //
//////////////////////////

if (ZsblRomEnable) begin : gen_zsbl_rom
    reg_rom #(
        .NumWords  ( ZsblRomWords ),
        .Data      ( ZsblRomProg  ),
        .BaseAddr  ( ZsblBaseAddr ),
        .reg_req_t ( reg_req_t    ),
        .reg_rsp_t ( reg_rsp_t    )
    ) zsbl_rom (
        .clk_i,
        .rst_ni    ( soc_rst_n             ),
        .reg_req_i ( reg_dev_req[ZsblPort] ),
        .reg_rsp_o ( reg_dev_rsp[ZsblPort] )
    );
end else begin : gen_no_zsbl_rom
    `REG_TIE_OFF(ZsblPort)
end

vernii_scb #(
    .NumPads    ( NumStraps ),
    .reg_req_t  ( reg_req_t ),
    .reg_rsp_t  ( reg_rsp_t ),
    .OcmLlcWays ( Ways      )
) i_scb (
    .clk_i,
    .rst_ni          ( soc_rst_n            ),
    .reg_req_i       ( reg_dev_req[ScbPort] ),
    .reg_rsp_o       ( reg_dev_rsp[ScbPort] ),
    .strap_i,
    .llcsel_o        ( llcsel               ),
    .crpsel_o        ( crpsel               ),
    .llcinv_o        ( llcinv               ),
    .inc_llcrdacc_i  ( llc_rd_acc           ),
    .inc_llcrdmiss_i ( llc_rd_miss          ),
    .inc_llcwracc_i  ( llc_wr_acc           )
);

///////////////////////////////
// External Memory Interface //
///////////////////////////////

friscv_to_axi4_full #(
    .BurstLen  ( LineBytes / StrbWidth ),
    .axi_req_t ( axi_req_t             ),
    .axi_rsp_t ( axi_rsp_t             )
) i_m_axi_bridge (
    .clk_i,
    .rst_ni      ( soc_rst_n      ),
    .s_req_i     ( ext_req        ),
    .s_rsp_o     ( ext_rsp        ),
    .m_axi_req_o ( m_axi_hp_req_o ),
    .m_axi_rsp_i ( m_axi_hp_rsp_i )
);

//////////////
// Debugger //
//////////////

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
) i_dm (
    // Keep the DM and DTM on the power-on reset so debug survives an ndmreset
    .clk_i,
    .rst_ni               ( por_rst_n      ),

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

logic jtag_trst_n, jtag_trst_n_async;

assign jtag_trst_n_async = rst_ni & jtag_trst_ni;

`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
rstgen i_rstgen_tck (
    .clk_i       ( jtag_tck_i        ),
    .rst_ni      ( jtag_trst_n_async ),
    .test_mode_i ( test_mode_i       ),
    .rst_no      ( jtag_trst_n       ),
    .init_no     (                   )
);
`pragma diagnostic pop

dmi_jtag #(
    .IdcodeValue ( 32'h00000DB3 )
) i_dmi (
    .clk_i,
    .rst_ni           ( por_rst_n      ),
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
    .trst_ni          ( jtag_trst_n    ),
    .td_i             ( jtag_tdi_i     ),
    .td_o             ( jtag_tdo_o     ),
    .tdo_oe_o         ( jtag_tdo_oe_o  )
);

reg_to_mem #(
    .AW    ( 32        ),
    .DW    ( 32        ),
    .req_t ( reg_req_t ),
    .rsp_t ( reg_rsp_t )
) i_dm_reg_to_mem (
    .clk_i,
    .rst_ni    ( soc_rst_n           ),
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
always_ff @(posedge clk_i or negedge soc_rst_n) begin
    if (!soc_rst_n) dbg_slv_rvalid <= 1'b0;
    else            dbg_slv_rvalid <= dbg_slv_req & ~dbg_slv_we;
end

// DM SBA master port: dm master -> bridge -> mem hub DM port
mem_to_friscv i_sba_mem (
    .clk_i,
    .rst_ni      ( soc_rst_n     ),
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
    .m_req_o     ( dm_req        ),
    .m_rsp_i     ( dm_rsp        )
);

/////////////////////////////////////////////////
// UART0: reg demux -> reg_bus -> APB -> UART0 //
/////////////////////////////////////////////////

// reg_bus -> APB
apb_req_t  uart0_apb_req;
apb_resp_t uart0_apb_rsp;
reg_to_apb #(
    .reg_req_t ( reg_req_t  ),
    .reg_rsp_t ( reg_rsp_t  ),
    .apb_req_t ( apb_req_t  ),
    .apb_rsp_t ( apb_resp_t )
) i_reg_to_apb (
    .clk_i,
    .rst_ni    ( soc_rst_n              ),
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
) i_uart0 (
    .clk_i,
    .rst_ni    ( soc_rst_n     ),
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

/////////////////
// GPIO Port A //
/////////////////

logic [31:0] gpio_a_irq;

gpio #(
    .reg_req_t   ( reg_req_t ),
    .reg_rsp_t   ( reg_rsp_t ),
    .GpioAsyncOn ( 1         )
) i_gpio_a (
    .clk_i,
    .rst_ni        ( soc_rst_n              ),
    .reg_req_i     ( reg_dev_req[GpioAPort] ),
    .reg_rsp_o     ( reg_dev_rsp[GpioAPort] ),
    .intr_gpio_o   ( gpio_a_irq             ),
    .cio_gpio_i    ( gpio_a_i               ),
    .cio_gpio_o    ( gpio_a_o               ),
    .cio_gpio_en_o ( gpio_a_oe_o            )
);

///////////
// QSPI0 //
///////////

logic qspi0_irq_error, qspi0_irq_spi_event;

spi_host #(
    .reg_req_t ( reg_req_t ),
    .reg_rsp_t ( reg_rsp_t )
) i_qspi0 (
    .clk_i,
    .rst_ni           ( soc_rst_n              ),
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

//////////
// PLIC //
//////////

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
    $fatal(1, "NumGpioAIrq (%0d) more than the 32 GPIO port A pins", NumGpioAIrq);
end
if (NIrqUsed > NIrqSources) begin : gen_chk_irq_budget
    $fatal(1, "the interrupt allocation needs %0d sources but the PLIC has %0d, reduce NumGpioAIrq (%0d) or NumExtIrq (%0d)",
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
            .rst_ni   ( soc_rst_n        ),
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
) i_plic (
    .clk_i,
    .rst_ni        ( soc_rst_n              ),
    .req_i         ( reg_dev_req[PlicPort] ),
    .resp_o        ( reg_dev_rsp[PlicPort] ),
    .le_i          ( '0                    ),  // All level-held
    .irq_sources_i ( plic_irq_sources      ),
    .eip_targets_o ( plic_irq_targets      )
);

///////////////////////////////////////////
// CLINT: reg demux -> reg_bus -> ACLINT //
///////////////////////////////////////////

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
) i_aclint (
    .clk_i,
    .rst_ni     ( soc_rst_n              ),
    .reg_req_i  ( clint_reg_req          ),
    .reg_rsp_o  ( reg_dev_rsp[ClintPort] ),
    .mtip_o     ( mtip                   ),
    .msip_o     ( msip                   ),
    .ssip_set_o (                        ),
    .mtime_o    ( mtime                  )
);
`pragma diagnostic pop

endmodule

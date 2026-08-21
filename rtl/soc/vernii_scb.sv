// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
//
// Emil Popović <mail@emilpopovic.me>

/*
 * System Control Block
 */

module vernii_scb
    import vernii_pkg::*;
#(
    parameter int unsigned    BootSelW   = 2,
    parameter int unsigned    OcmLlcWays = 4,
    parameter vernii_syscfg_t SysCfg     = '0,
    parameter type            reg_req_t  = vernii_reg_req_t,
    parameter type            reg_rsp_t  = vernii_reg_rsp_t
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  reg_req_t reg_req_i,
    output reg_rsp_t reg_rsp_o,

    input  logic [BootSelW-1:0]   boot_sel_i,

    output logic [OcmLlcWays-1:0] llcsel_o,
    output logic                  crpsel_o,
    output logic                  llcinv_o,

    input  logic                  inc_llcrdacc_i,
    input  logic                  inc_llcrdmiss_i,
    input  logic                  inc_llcwracc_i
);

localparam logic [11:0] OFF_SCRATCH0   = 12'h000;
localparam logic [11:0] OFF_BOOTSEL    = 12'h004;
localparam logic [11:0] OFF_LLCSEL     = 12'h00C;
localparam logic [11:0] OFF_LLCCRPSEL  = 12'h010;
localparam logic [11:0] OFF_LLCINV     = 12'h014;
localparam logic [11:0] OFF_LLCRDACCL  = 12'h018;
localparam logic [11:0] OFF_LLCRDACCH  = 12'h01C;
localparam logic [11:0] OFF_LLCRDMISSL = 12'h020;
localparam logic [11:0] OFF_LLCRDMISSH = 12'h024;
localparam logic [11:0] OFF_LLCWRACCL  = 12'h028;
localparam logic [11:0] OFF_LLCWRACCH  = 12'h02C;

localparam logic [11:0] OFF_SYSID         = 12'h100;
localparam logic [11:0] OFF_SYSIMPL       = 12'h104;
localparam logic [11:0] OFF_SYSVER        = 12'h108;
localparam logic [11:0] OFF_SYSFEAT       = 12'h10C;
localparam logic [11:0] OFF_SYSCACHECFG   = 12'h110;
localparam logic [11:0] OFF_SYSMMUCFG     = 12'h114;
localparam logic [11:0] OFF_SYSIRQCFG     = 12'h118;
localparam logic [11:0] OFF_SYSBUSCFG     = 12'h11C;
localparam logic [11:0] OFF_SYSBOOTCFG    = 12'h120;
localparam logic [11:0] OFF_SYSOCMBASE    = 12'h124;
localparam logic [11:0] OFF_SYSOCMSIZE    = 12'h128;
localparam logic [11:0] OFF_SYSEXTBASE    = 12'h12C;
localparam logic [11:0] OFF_SYSEXTSIZE    = 12'h130;
localparam logic [11:0] OFF_SYSCACHEDBASE = 12'h134;
localparam logic [11:0] OFF_SYSCACHEDSIZE = 12'h138;

localparam bit LlcPresent = SysCfg.llc;

logic [11:0] off;
assign off = reg_req_i.addr[11:0];

logic do_write;
assign do_write = reg_req_i.valid && reg_req_i.write;

///////////////
// Registers //
///////////////

logic [31:0]           scratch0;  // SCRATCH0
logic [BootSelW-1:0]   bootsel;   // BOOTSEL
logic [OcmLlcWays-1:0] llcsel;    // LLCSEL
logic                  llccrpsel; // LLCCRPSEL
logic                  llcinv;    // LLCINV
logic [63:0]           llcrdacc;  // LLCRDACC
logic [63:0]           llcrdmiss; // LLCRDMISS
logic [63:0]           llcwracc;  // LLCWRACC

logic inc_llcrdacc, inc_llcrdmiss, inc_llcwracc;

// Register increment of wide counters
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        inc_llcrdacc  <= 1'b0;
        inc_llcrdmiss <= 1'b0;
        inc_llcwracc  <= 1'b0;
    end else begin
        inc_llcrdacc  <= inc_llcrdacc_i;
        inc_llcrdmiss <= inc_llcrdmiss_i;
        inc_llcwracc  <= inc_llcwracc_i;
    end
end

for (genvar i = 0; i < BootSelW; i++) begin : gen_boot_sel_sync
    tc_sync #(
        .Stages     ( 2    ),
        .ResetValue ( 1'b0 )
    ) i_sync_boot_sel (
        .clk_i,
        .rst_ni,
        .serial_i ( boot_sel_i[i] ),
        .serial_o ( bootsel[i]    )
    );
end

///////////
// Write //
///////////

// SCRATCH0
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) scratch0 <= '0;
    else if (do_write && off == OFF_SCRATCH0) begin
        for (int i = 0; i < 4; i++) begin
            if (reg_req_i.wstrb[i])
                scratch0[8*i +: 8] <= reg_req_i.wdata[8*i +: 8];
        end
    end
end

// LLCSEL
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) llcsel <= '0;
    else if (do_write && off == OFF_LLCSEL && reg_req_i.wstrb[0]) begin
        llcsel <= reg_req_i.wdata[OcmLlcWays-1:0];
    end
end

// LLCCRPSEL
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) llccrpsel <= '0;
    else if (do_write && off == OFF_LLCCRPSEL && reg_req_i.wstrb[0]) begin
        llccrpsel <= reg_req_i.wdata[0];
    end
end

// LLCINV
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) llcinv <= 1'b0;
    else
        // Write one to request an invalidate, then self-clear
        llcinv <= do_write && off == OFF_LLCINV && reg_req_i.wstrb[0] && reg_req_i.wdata[0];
end

// LLCRDACC
// Clear on any write, increment on signal if no write
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
        llcrdacc <= '0;
    else if (do_write && (off == OFF_LLCRDACCL || off == OFF_LLCRDACCH))
        llcrdacc <= '0;
    else if (inc_llcrdacc)
        llcrdacc <= llcrdacc + 1'b1;
end

// LLCRDMISS
// Clear on any write, increment on signal if no write
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
        llcrdmiss <= '0;
    else if (do_write && (off == OFF_LLCRDMISSL || off == OFF_LLCRDMISSH))
        llcrdmiss <= '0;
    else if (inc_llcrdmiss)
        llcrdmiss <= llcrdmiss + 1'b1;
end

// LLCWRACC
// Clear on any write, increment on signal if no write
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
        llcwracc  <= '0;
    else if (do_write && (off == OFF_LLCWRACCL || off == OFF_LLCWRACCH))
        llcwracc <= '0;
    else if (inc_llcwracc)
        llcwracc <= llcwracc + 1'b1;
end

assign llcsel_o = llcsel;
assign crpsel_o = llccrpsel;
assign llcinv_o = llcinv;

////////////////////
// Identification //
////////////////////

// SYSIMPL
localparam logic [31:0] SysImpl = {SysIdVernii, SysCfg.variant};

// SYSVER
localparam logic [31:0] SysVer = {SysVerMajor, SysVerMinor, SysVerPatch,
                                  7'h0, SysVerRelease};

// SYSFEAT
localparam logic [31:0] SysFeat = {
    15'h0,                  // [31:17]  reserved
    SysCfg.halt_on_end,     // [16]    HALTONEND
    2'h0,                   // [15:14]  reserved
    SysCfg.s_axi_gp,        // [13]    SAXIGP
    SysCfg.zsbl_rom,        // [12]    ZSBLROM
    SysCfg.fast_mul,        // [11]    FASTMUL
    SysCfg.isa_a,           // [10]    ISAA
    SysCfg.isa_m,           // [9]     ISAM
    SysCfg.isa_e,           // [8]     ISAE
    SysCfg.ptw_pmp,         // [7]     PTWPMP
    SysCfg.pmp,             // [6]     PMP
    SysCfg.fine_tlb_flush,  // [5]     FINETLBFLUSH
    SysCfg.mmu,             // [4]     MMU
    1'b0,                   // [3]      reserved
    SysCfg.sram_tags,       // [2]     SRAMTAGS
    SysCfg.llc,             // [1]     LLC
    SysCfg.ocm              // [0]     OCM
};

// SYSCACHECFG..SYSBOOTCFG
localparam logic [31:0] SysCacheCfg = {8'h0, SysCfg.ways, SysCfg.line_bytes};

localparam logic [31:0] SysMmuCfg = {8'h0, SysCfg.pmp_entries,
                                     SysCfg.dtlb_entries, SysCfg.itlb_entries};

localparam logic [31:0] SysIrqCfg = {16'h0, SysCfg.num_gpio_a_irq,
                                     SysCfg.num_ext_irq};

localparam logic [31:0] SysBusCfg = {16'h0, SysCfg.num_s_axi_gp_rules,
                                     SysCfg.num_m_reg_rules};

localparam logic [31:0] SysBootCfg = {8'h0, SysCfg.boot_sel_w,
                                      SysCfg.zsbl_rom_words};

/////////////////////
// Read / Response //
/////////////////////

logic [31:0] rdata;
logic        map_err;

always_comb begin
    rdata   = 32'h0;
    map_err = 1'b0;
    unique case (off)
        OFF_SCRATCH0:   rdata = scratch0;
        OFF_BOOTSEL:    rdata = 32'(bootsel);
        // LLC* are only accessible if the config built an LLC
        OFF_LLCSEL:
            if (LlcPresent) rdata = {{32-OcmLlcWays{1'b0}}, {llcsel}};
            else map_err = 1'b1;
        OFF_LLCCRPSEL:
            if (LlcPresent) rdata = {31'h0, llccrpsel};
            else map_err = 1'b1;
        OFF_LLCINV:
            if (LlcPresent) rdata = 32'h0;   // write-only
            else map_err = 1'b1;
        OFF_LLCRDACCL:
            if (LlcPresent) rdata = llcrdacc [31:0];
            else map_err = 1'b1;
        OFF_LLCRDACCH:
            if (LlcPresent) rdata = llcrdacc [63:32];
            else map_err = 1'b1;
        OFF_LLCRDMISSL:
            if (LlcPresent) rdata = llcrdmiss[31:0];
            else map_err = 1'b1;
        OFF_LLCRDMISSH:
            if (LlcPresent) rdata = llcrdmiss[63:32];
            else map_err = 1'b1;
        OFF_LLCWRACCL:
            if (LlcPresent) rdata = llcwracc [31:0];
            else map_err = 1'b1;
        OFF_LLCWRACCH:
            if (LlcPresent) rdata = llcwracc [63:32];
            else map_err = 1'b1;

        // Identification, read-only
        OFF_SYSID:         rdata = SysIdMagic;
        OFF_SYSIMPL:       rdata = SysImpl;
        OFF_SYSVER:        rdata = SysVer;
        OFF_SYSFEAT:       rdata = SysFeat;
        OFF_SYSCACHECFG:   rdata = SysCacheCfg;
        OFF_SYSMMUCFG:     rdata = SysMmuCfg;
        OFF_SYSIRQCFG:     rdata = SysIrqCfg;
        OFF_SYSBUSCFG:     rdata = SysBusCfg;
        OFF_SYSBOOTCFG:    rdata = SysBootCfg;
        OFF_SYSOCMBASE:    rdata = SysCfg.ocm_base;
        OFF_SYSOCMSIZE:    rdata = SysCfg.ocm_size;
        OFF_SYSEXTBASE:    rdata = SysCfg.ext_base;
        OFF_SYSEXTSIZE:    rdata = SysCfg.ext_size;
        OFF_SYSCACHEDBASE: rdata = SysCfg.cached_base;
        OFF_SYSCACHEDSIZE: rdata = SysCfg.cached_size;

        default: map_err = 1'b1;
    endcase
end

assign reg_rsp_o.rdata = rdata;
assign reg_rsp_o.ready = 1'b1;
assign reg_rsp_o.error = reg_req_i.valid && map_err;

endmodule

// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements a single FRISC-V core, with everything that is local to the core (including the MMU and AMO unit) integrated into a single module.
 * Never instantiate a core without this wrapper.
 */

module friscv_core import friscv_pkg::*, friscv_mem_pkg::*; #(
    parameter int unsigned HartId           = 0,
    parameter int unsigned ResetVec         = 32'h8000_0000,
    parameter bit          ZsblRomEnable    = 1'b0,
    parameter int unsigned ZsblRomWords     = 1,
    parameter logic [31:0] ZsblRomProg [ZsblRomWords] = '{default: '0},
    parameter int unsigned DmBase           = 32'h0000_0000,
    parameter int unsigned DmHaltOffset     = 32'h800,
    parameter int unsigned DmExcOffset      = 32'h810,

    // Memory protection and address translation
    parameter bit EnableMmu     = 1,
    parameter bit EnforcePmp    = 0,
    parameter bit EnforcePtwPmp = 0,
    parameter int unsigned PmpEntries  = 8,
    parameter int unsigned PmpUsable   = 8,
    // Must be a power of 2 greater than 1
    parameter int unsigned ItlbEntries = 2,
    parameter int unsigned DtlbEntries = 4,
    // If not enabled, any sfence.vma will flush all TLB entries
    parameter bit EnableFineTlbFlush = 0,

    // Extension selection
    parameter bit EnableIsaM    = 1,
    // Use a single-cycle combinational multiplier instead of the iterative multiplier
    parameter bit EnableFastMul = 0,
    parameter bit EnableIsaA    = 1,
    // If enabled, a write to END_ADDRESS will stall the core until reset
    parameter bit HaltOnEndAddress = 0,
    // If enabled, entering an EBREAK instruction will halt the core until reset
    parameter bit HaltOnEnterEbreak = 0,
    // If enabled, the first MRET or SRET after entering an EBREAK handler will halt the core until reset
    parameter bit HaltOnRetFromEbreak = 0
) (
    input  logic       i_clk,
    input  logic       i_rstn,
    output logic       o_end,
    input  logic       i_msip,
    input  logic       i_mtip,
    input  logic       i_meip,
    input  logic       i_seip,
    input  mtime_t     i_mtime,

    output mem_width_e o_mem_size,
    output addr_t      o_mem_addr,
    output data_t      o_mem_wdata,
    input  data_t      i_mem_rdata,
    output rw_cmd_e    o_mem_rw,
    input  logic       i_mem_wait,
    input  logic       i_mem_err,
    output logic       o_burst_en,

    input  logic       i_dbg_req
);

// Elaboration-time parameter checks
if (!EnableIsaM && EnableFastMul) begin : gen_chk_fast_mul_has_mul
    $fatal(1, "EnableFastMul enabled, but EnableIsaM disabled. Fast multiplier requires M extension.");
end
if (!EnableMmu && EnforcePmp) begin : gen_chk_pmp_requires_mmu
    $fatal(1, "EnforcePmp enabled, but EnableMmu disabled. PMP enforcement requires MMU.");
end
if (!EnforcePmp && EnforcePtwPmp) begin : gen_chk_ptw_pmp_requires_pmp
    $fatal(1, "EnforcePtwPmp enabled, but EnforcePmp disabled. PTW PMP enforcement requires PMP enforcement.");
end
if (PmpUsable > PmpEntries) begin : gen_chk_pmp_usable_le_entries
    $fatal(1, "PmpUsable (%0d) exceeds PmpEntries (%0d).", PmpUsable, PmpEntries);
end
if (PmpEntries > 64) begin : gen_chk_pmp_entries_le_64
    $fatal(1, "PmpEntries (%0d) exceeds the maximum of 64.", PmpEntries);
end

// ============================================================
// Level 1 bus: instruction and data memory interfaces
// ============================================================

// Instruction L1 bus
addr_t      w_inst_addr;
data_t      w_inst_data;
logic       w_inst_en;
logic       w_inst_wait;
logic       w_inst_err;
logic       w_stall_if;
inst_t      w_zsbl_data;

// Data L1 bus
addr_t      w_data_addr;
data_t      w_data_wdata;
data_t      w_data_rdata;
logic       w_data_en;
logic       w_data_wr;
logic       w_data_store_like;
mem_width_e w_data_size;
logic       w_data_wait;
logic       w_data_err;
amo_op_e    w_amo_op;
logic       w_ex_mem_inflight;

// ============================================================
// Protection and Translation signals
// ============================================================

satp_t w_satp;
logic  w_sum;
logic  w_mxr;
mode_e w_mode;
mode_e w_data_mode;
logic  w_flush_tlb;
vpn_t  w_flush_vpn;
logic  w_flush_vpn_en;
asid_t w_flush_asid;
logic  w_flush_asid_en;

// ============================================================
// Level 2 bus and L1-L2 arbitration
// ============================================================

addr_t      w_l2_req_addr;
mem_width_e w_l2_req_size;
data_t      w_l2_req_wdata;
rw_cmd_e    w_l2_req_rw;
data_t      w_l2_req_rdata;
logic       w_l2_req_wait;
logic       w_l2_req_err;
amo_op_e    w_l2_req_amo_op;

addr_t      w_l2_addr;
mem_width_e w_l2_size;
data_t      w_l2_wdata;
rw_cmd_e    w_l2_rw;
data_t      w_l2_backend_rdata;
logic       w_l2_backend_wait;
logic       w_l2_backend_err;
amo_op_e    w_l2_amo_op;

// AMO unit signals
rw_cmd_e    w_amo_rw;
data_t      w_amo_store_data;
data_t      w_amo_load_data;
logic       w_amo_core_wait;
logic       w_amo_active;
logic       w_amo_start;
logic       w_amo_bootstrap;
logic       r_amo_addr_valid;
addr_t      r_amo_addr;
mem_width_e r_amo_size;

assign w_amo_start = (w_l2_amo_op != AMO_NONE) &&
                     (w_l2_rw != RW_IDLE) &&
                     !r_amo_addr_valid;
assign w_amo_bootstrap = (w_l2_amo_op != AMO_NONE) && !r_amo_addr_valid;

always_ff @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn) begin
        r_amo_addr_valid <= 1'b0;
        r_amo_addr       <= '0;
        r_amo_size       <= WIDTH_I32;
    end else begin
        // Freeze AMO target address and size for the whole LOAD-STORE sequence
        if (w_amo_start) begin
            r_amo_addr_valid <= 1'b1;
            r_amo_addr       <= w_l2_addr;
            r_amo_size       <= w_l2_size;
        end else if (r_amo_addr_valid && w_amo_rw == RW_IDLE) begin
            r_amo_addr_valid <= 1'b0;
        end
    end
end

assign o_mem_size  = w_amo_active ? (r_amo_addr_valid ? r_amo_size : w_l2_size) : w_l2_size;
assign o_mem_addr  = w_amo_active ? (r_amo_addr_valid ? r_amo_addr : w_l2_addr) : w_l2_addr;
assign o_mem_wdata = w_amo_active ? w_amo_store_data : w_l2_wdata;

// Page fault signals
logic  w_inst_fault, w_load_fault, w_store_fault;
addr_t w_fault_addr;

pmp_entry_t [PmpEntries-1:0] w_pmp_table;
logic w_inst_pmp_fault, w_data_pmp_fault;

// The MMU contains an arbiter.
// If the MMU is disabled, a bare arbiter is instantiated instead.
`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
if (EnableMmu) begin : gen_mmu
    friscv_mmu #(
        .EnforcePmp         ( EnforcePmp         ),
        .EnforcePtwPmp      ( EnforcePtwPmp      ),
        .PmpEntries         ( PmpEntries         ),
        .ItlbEntries        ( ItlbEntries        ),
        .DtlbEntries        ( DtlbEntries        ),
        .EnableFineTlbFlush ( EnableFineTlbFlush )
    ) mmu (
        .i_clk           ( i_clk           ),
        .i_rstn          ( i_rstn          ),

        // Instruction Memory Interface
        .i_inst_addr     ( w_inst_addr     ),
        .o_inst_data     ( w_inst_data     ),
        .i_inst_en       ( w_inst_en       ),
        .o_inst_wait     ( w_inst_wait     ),
        .o_inst_err      ( w_inst_err      ),
        .o_inst_pmp_fault( w_inst_pmp_fault),

        // Data Memory Interface
        .i_data_addr     ( w_data_addr     ),
        .i_data_size     ( w_data_size     ),
        .i_data_wdata    ( w_data_wdata    ),
        .o_data_rdata    ( w_data_rdata    ),
        .i_data_en       ( w_data_en       ),
        .i_data_wr       ( w_data_wr       ),
        .i_data_store_like ( w_data_store_like ),
        .o_data_wait     ( w_data_wait     ),
        .o_data_err      ( w_data_err      ),
        .o_data_pmp_fault( w_data_pmp_fault),
        .i_amo_op        ( w_amo_op        ),

        // External Memory Interface
        .o_mem_size      ( w_l2_req_size   ),
        .o_mem_addr      ( w_l2_req_addr   ),
        .o_mem_wdata     ( w_l2_req_wdata  ),
        .i_mem_rdata     ( w_l2_req_rdata  ),
        .o_mem_rw        ( w_l2_req_rw     ),
        .i_mem_wait      ( w_l2_req_wait   ),
        .i_mem_err       ( w_l2_req_err    ),
        .o_amo_op        ( w_l2_req_amo_op ),

        // Protection and Translation Control
        .i_satp          ( w_satp          ),
        .i_sum           ( w_sum           ),
        .i_mxr           ( w_mxr           ),
        .i_inst_mode     ( w_mode          ),
        .i_data_mode     ( w_data_mode     ),
        .i_flush_tlb     ( w_flush_tlb     ),
        .i_flush_vpn     ( w_flush_vpn     ),
        .i_flush_vpn_en  ( w_flush_vpn_en  ),
        .i_flush_asid    ( w_flush_asid    ),
        .i_flush_asid_en ( w_flush_asid_en ),
        .i_pmp_table     ( w_pmp_table     ),

        // Page fault signals
        .o_inst_fault    ( w_inst_fault    ),
        .o_load_fault    ( w_load_fault    ),
        .o_store_fault   ( w_store_fault   ),
        .o_fault_addr    ( w_fault_addr    )
    );
end else begin : gen_no_mmu
    friscv_l1_arbiter l1_arbiter (
        .i_clk        ( i_clk           ),
        .i_rstn       ( i_rstn          ),

        .i_inst_addr  ( w_inst_addr     ),
        .o_inst_data  ( w_inst_data     ),
        .i_inst_en    ( w_inst_en       ),
        .o_inst_wait  ( w_inst_wait     ),
        .o_inst_err   ( w_inst_err      ),

        .i_data_addr  ( w_data_addr     ),
        .i_data_size  ( w_data_size     ),
        .i_data_wdata ( w_data_wdata    ),
        .o_data_rdata ( w_data_rdata    ),
        .i_data_en    ( w_data_en       ),
        .i_data_wr    ( w_data_wr       ),
        .o_data_wait  ( w_data_wait     ),
        .o_data_err   ( w_data_err      ),
        .i_amo_op     ( w_amo_op        ),

        .o_mem_addr   ( w_l2_req_addr   ),
        .o_mem_size   ( w_l2_req_size   ),
        .o_mem_wdata  ( w_l2_req_wdata  ),
        .i_mem_rdata  ( w_l2_req_rdata  ),
        .o_mem_rw     ( w_l2_req_rw     ),
        .i_mem_wait   ( w_l2_req_wait   ),
        .i_mem_err    ( w_l2_req_err    ),
        .o_amo_op     ( w_l2_req_amo_op ),
        .o_grant_start(                 ),
        .o_grant_start_inst(            ),
        .o_grant_held (                 )
    );

    assign w_inst_fault  = 1'b0;
    assign w_load_fault  = 1'b0;
    assign w_store_fault = 1'b0;
    assign w_fault_addr  = '0;
    assign w_inst_pmp_fault = 1'b0;
    assign w_data_pmp_fault = 1'b0;
end
`pragma diagnostic pop

// ============================================================
// Level 2 bus
// ============================================================

assign w_l2_addr   = w_l2_req_addr;
assign w_l2_size   = w_l2_req_size;
assign w_l2_wdata  = w_l2_req_wdata;
assign w_l2_rw     = w_l2_req_rw;
assign w_l2_amo_op = (w_l2_req_rw != RW_IDLE) ? w_l2_req_amo_op : AMO_NONE;

assign w_l2_req_wait  = w_l2_backend_wait;
assign w_l2_req_err   = w_l2_backend_err;
assign w_l2_req_rdata = w_l2_backend_rdata;

// ============================================================
// End signal detection on write to END_ADDRESS
// ============================================================

logic r_end_signal;
logic r_halt_active;
logic w_core_halt;

always_ff @(posedge i_clk or negedge i_rstn) begin
    if (!i_rstn) begin
        r_end_signal  <= 1'b0;
        r_halt_active <= 1'b0;
    end else if (HaltOnEndAddress && w_data_addr == END_ADDRESS && w_data_en && w_data_wr) begin
        r_end_signal  <= 1'b1;
        r_halt_active <= 1'b1;
    end else begin
        if (w_core_halt)
            r_halt_active <= 1'b1;
        if (r_halt_active && !w_ex_mem_inflight && !w_data_en)
            r_end_signal <= 1'b1;
    end
end

assign o_end = r_end_signal;
assign w_stall_if = w_inst_wait;

// ============================================================
// Core instance
// ============================================================

friscv_datapath #(
    .HartId              ( HartId              ),
    .ResetVec            ( ResetVec            ),
    .DmBase              ( DmBase              ),
    .DmHaltOffset        ( DmHaltOffset        ),
    .DmExcOffset         ( DmExcOffset         ),
    .EnableMmu           ( EnableMmu           ),
    .EnforcePmp          ( EnforcePmp          ),
    .PmpEntries          ( PmpEntries          ),
    .PmpUsable           ( PmpUsable           ),
    .EnableIsaM          ( EnableIsaM          ),
    .EnableFastMul       ( EnableFastMul       ),
    .EnableIsaA          ( EnableIsaA          ),
    .HaltOnEnterEbreak   ( HaltOnEnterEbreak   ),
    .HaltOnRetFromEbreak ( HaltOnRetFromEbreak )
) cpu_0 (
    .i_clk            ( i_clk           ),
    .i_rstn           ( i_rstn          ),
    .o_halt           ( w_core_halt     ),
    .i_halt           ( r_halt_active   ),
    .o_ex_mem_inflight( w_ex_mem_inflight ),

    // Interrupt requests
    .i_msip           ( i_msip          ),
    .i_mtip           ( i_mtip          ),
    .i_meip           ( i_meip          ),
    .i_seip           ( i_seip          ),

    // CLINT time
    .i_mtime          ( i_mtime         ),

    // Page fault signals
    .i_inst_fault     ( w_inst_fault    ),
    .i_load_fault     ( w_load_fault    ),
    .i_store_fault    ( w_store_fault   ),
    .i_fault_addr     ( w_fault_addr    ),

    // Instruction Memory Interface
    .i_mem_addr_out   ( w_inst_addr     ),
    .i_mem_data_in    ( w_inst_data     ),
    .i_mem_en_out     ( w_inst_en       ),
    .i_mem_wait_in    ( w_stall_if      ),
    .i_mem_err_in     ( w_inst_err      ),
    .i_mem_pmp_fault_in ( w_inst_pmp_fault ),

    // Data memory interface
    .d_mem_addr_out   ( w_data_addr     ),
    .d_mem_data_out   ( w_data_wdata    ),
    .d_mem_data_in    ( w_data_rdata    ),
    .d_mem_en_out     ( w_data_en       ),
    .d_mem_wr_out     ( w_data_wr       ),
    .d_mem_store_like_out ( w_data_store_like ),
    .d_mem_size_out   ( w_data_size     ),
    .d_mem_wait_in    ( w_data_wait     ),
    .d_mem_err_in     ( w_data_err      ),
    .d_mem_pmp_fault_in ( w_data_pmp_fault ),
    .d_mem_amo_op_out ( w_amo_op        ),

    // Memory management outputs
    .satp_out         ( w_satp          ),
    .sum_out          ( w_sum           ),
    .mxr_out          ( w_mxr           ),
    .mode_out         ( w_mode          ),
    .data_mode_out    ( w_data_mode     ),
    .flush_tlb_out    ( w_flush_tlb     ),
    .flush_vpn_out    ( w_flush_vpn     ),
    .flush_vpn_en_out ( w_flush_vpn_en  ),
    .flush_asid_out   ( w_flush_asid    ),
    .flush_asid_en_out( w_flush_asid_en ),
    .pmp_table_out    ( w_pmp_table     ),

    .dbg_req_in       ( i_dbg_req       )
);

// ============================================================
// Atomic memory operations
// ============================================================

amo_op_e w_eff_amo;
assign w_eff_amo = r_amo_addr_valid ? w_l2_amo_op : AMO_NONE;

if (EnableIsaA) begin : gen_amo
    friscv_amo_unit amo_unit (
        .i_clk            ( i_clk            ),
        .i_rstn           ( i_rstn           ),
        .i_amo_op         ( w_eff_amo        ),
        .i_rs2_val        ( w_l2_wdata       ),
        .o_core_load_data ( w_amo_load_data  ),
        .o_core_wait      ( w_amo_core_wait  ),
        .i_mem_wait       ( i_mem_wait       ),
        .i_mem_err        ( i_mem_err        ),
        .o_mem_rw         ( w_amo_rw         ),
        .i_mem_load_data  ( i_mem_rdata      ),
        .o_mem_store_data ( w_amo_store_data )
    );
    // Keep AMO path selected across both LOAD and STORE phases
    assign w_amo_active = w_amo_bootstrap || (w_eff_amo != AMO_NONE) || (w_amo_rw != RW_IDLE);
end else begin : gen_no_amo
    assign w_amo_active     = 1'b0;
    assign w_amo_rw         = RW_IDLE;
    assign w_amo_store_data = '0;
    assign w_amo_load_data  = '0;
    assign w_amo_core_wait  = 1'b0;
    assign w_amo_bootstrap  = 1'b0;
end

// ============================================================
// Zero-stage bootloader
// ============================================================

if (ZsblRomEnable) begin : gen_zsbl_rom
    friscv_zsbl_rom #(
        .ProgWords ( ZsblRomWords ),
        .Prog      ( ZsblRomProg  ),
        .BaseAddr  ( ResetVec     )
    ) zsbl_rom (
        .i_clk  ( i_clk       ),
        .i_rstn ( i_rstn      ),
        .i_addr ( w_l2_addr   ),
        .o_data ( w_zsbl_data )
    );

    logic w_l2_is_rom;
    logic r_rom_valid;

    // Intercept reads in the ROM address window before they reach AXI
    assign w_l2_is_rom = (w_l2_addr >= ResetVec) &&
                         (w_l2_addr < ResetVec + ZsblRomWords * 4) &&
                         (w_l2_rw == RW_READ);

    always_ff @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_rom_valid <= 1'b0;
        end else begin
            r_rom_valid <= w_l2_is_rom && !r_rom_valid;
        end
    end

    assign w_l2_backend_rdata = r_rom_valid ? w_zsbl_data :
                                w_amo_active ? w_amo_load_data : i_mem_rdata;

    assign w_l2_backend_wait = r_rom_valid ? 1'b0 :
                               w_amo_bootstrap ? 1'b1 :
                               w_amo_active ? w_amo_core_wait : i_mem_wait;

    assign w_l2_backend_err = r_rom_valid ? 1'b0 : i_mem_err;

    assign o_mem_rw   = w_l2_is_rom ? RW_IDLE :
                        w_amo_bootstrap ? RW_IDLE :
                        w_amo_active ? w_amo_rw :
                        w_l2_rw;

end else begin : gen_no_zsbl_rom
    // No ROM, pass through all reads/writes to AXI (or AMO unit)
    assign w_l2_backend_rdata = w_amo_active ? w_amo_load_data : i_mem_rdata;
    assign w_l2_backend_wait  = w_amo_bootstrap ? 1'b1 :
                                w_amo_active ? w_amo_core_wait :
                                i_mem_wait;
    assign w_l2_backend_err = i_mem_err;
    assign o_mem_rw   = w_amo_bootstrap ? RW_IDLE :
                        w_amo_active ? w_amo_rw :
                        w_l2_rw;
end

assign o_burst_en = 1'b0;

endmodule

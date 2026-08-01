// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the Memory Management Unit (MMU) of the FRISC-V CPU subsystem.
 * It handles virtual to physical address translation, TLB management, page fault generation, and memory interface arbitration.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_mmu #(
    parameter logic ENFORCE_PMP     = 0,
    parameter logic ENFORCE_PTW_PMP = 0,
    parameter int   PMP_ENTRIES     = 64,
    // Must be a power of 2 greater than 1
    parameter int   ITLB_ENTRIES = 2,
    parameter int   DTLB_ENTRIES = 4,
    // If not enabled, any sfence.vma will flush all TLB entries
    parameter logic ENABLE_FINE_TLB_FLUSH = 0
) (
    input  logic        i_clk,
    input  logic        i_rstn,

    // Instruction Memory Interface
    input  addr_t       i_inst_addr,
    output data_t       o_inst_data,
    input  logic        i_inst_en,
    output logic        o_inst_wait,
    output logic        o_inst_err,
    output logic        o_inst_pmp_fault,

    // Data Memory Interface
    input  addr_t       i_data_addr,
    input  mem_width_e  i_data_size,
    input  data_t       i_data_wdata,
    output data_t       o_data_rdata,
    input  logic        i_data_en,
    input  logic        i_data_wr,
    input  logic        i_data_store_like,
    output logic        o_data_wait,
    output logic        o_data_err,
    output logic        o_data_pmp_fault,
    input  amo_op_e     i_amo_op,

    // External Memory Interface
    output addr_t       o_mem_addr,
    output mem_width_e  o_mem_size,
    output data_t       o_mem_wdata,
    input  data_t       i_mem_rdata,
    output rw_cmd_e     o_mem_rw,
    input  logic        i_mem_wait,
    input  logic        i_mem_err,
    output amo_op_e     o_amo_op,

    // Protection and Translation Control
    input  satp_t       i_satp,
    input  logic        i_sum,
    input  logic        i_mxr,
    input  mode_e       i_inst_mode,
    input  mode_e       i_data_mode,
    input  logic        i_flush_tlb,
    input  vpn_t        i_flush_vpn,
    input  logic        i_flush_vpn_en,
    input  asid_t       i_flush_asid,
    input  logic        i_flush_asid_en,
    input  pmp_entry_t [PMP_ENTRIES-1:0] i_pmp_table,

    // Page fault signals
    output logic        o_inst_fault,
    output logic        o_load_fault,
    output logic        o_store_fault,
    output addr_t       o_fault_addr
);

// Granted request lines and latched translation context
addr_t        w_grant_addr;
mem_width_e   w_grant_size;
data_t        w_grant_wdata;
rw_cmd_e      w_grant_rw;
logic         w_stall;
amo_op_e      w_grant_amo;
logic         w_grant_inst;
logic         w_grant_start;
logic         w_grant_start_inst;
logic         w_grant_held;
logic         w_grant_wr;
logic         w_grant_active;
logic         w_l1_inst_err;
logic         w_l1_data_err;
mmu_req_ctx_t r_req_ctx;
mmu_req_ctx_t w_eff_req_ctx;
mmu_req_ctx_t w_start_req_ctx;
asid_t        w_eff_asid;

logic w_paging_en;

// ============================================================
// TLB layer
// ============================================================

vpn_t w_inst_vpn, w_data_vpn;
assign w_inst_vpn = (w_grant_active && w_eff_req_ctx.is_inst)  ? vpn_t'(w_eff_req_ctx.addr[31:12]) : vpn_t'(i_inst_addr[31:12]);
assign w_data_vpn = (w_grant_active && !w_eff_req_ctx.is_inst) ? vpn_t'(w_eff_req_ctx.addr[31:12]) : vpn_t'(i_data_addr[31:12]);

// Lookup lines
ppn_t       w_itlb_ppn, w_dtlb_ppn;
perm_t      w_itlb_perm, w_dtlb_perm;
pte_level_t w_itlb_level, w_dtlb_level;
logic       w_itlb_hit, w_dtlb_hit;

satp_mode_e w_tlb_mode;
assign w_tlb_mode = satp_mode_e'(w_eff_req_ctx.satp.mode);

// Fill lines
vpn_t       w_fill_vpn;
ppn_t       w_fill_ppn;
asid_t      w_fill_asid;
perm_t      w_fill_perm;
pte_level_t w_fill_level;
logic       w_fill_itlb, w_fill_dtlb;

// Physical addresses
addr_t w_inst_pa, w_data_pa;
assign w_inst_pa = w_paging_en ? {w_itlb_ppn, i_inst_addr[11:0]} : i_inst_addr;
assign w_data_pa = w_paging_en ? {w_dtlb_ppn, i_data_addr[11:0]} : i_data_addr;

friscv_tlb #(
    .ENTRY_COUNT           ( ITLB_ENTRIES          ),
    .ENABLE_FINE_TLB_FLUSH ( ENABLE_FINE_TLB_FLUSH )
) itlb (
    .i_clk           ( i_clk           ),
    .i_rstn          ( i_rstn          ),

    // Lookup
    .i_match_vpn     ( w_inst_vpn      ),
    .i_mode          ( w_tlb_mode      ),
    .i_match_asid    ( w_eff_asid      ),
    .o_ppn           ( w_itlb_ppn      ),
    .o_perm          ( w_itlb_perm     ),
    .o_level         ( w_itlb_level    ),
    .o_hit           ( w_itlb_hit      ),

    // Fill
    .i_fill_vpn      ( w_fill_vpn      ),
    .i_fill_ppn      ( w_fill_ppn      ),
    .i_fill_asid     ( w_fill_asid     ),
    .i_fill_perm     ( w_fill_perm     ),
    .i_fill_level    ( w_fill_level    ),
    .i_fill_en       ( w_fill_itlb     ),

    // Flush
    .i_flush         ( i_flush_tlb     ),
    .i_flush_vpn     ( i_flush_vpn     ),
    .i_flush_vpn_en  ( i_flush_vpn_en  ),
    .i_flush_asid    ( i_flush_asid    ),
    .i_flush_asid_en ( i_flush_asid_en )
);

friscv_tlb #(
    .ENTRY_COUNT           ( DTLB_ENTRIES          ),
    .ENABLE_FINE_TLB_FLUSH ( ENABLE_FINE_TLB_FLUSH )
) dtlb (
    .i_clk           ( i_clk           ),
    .i_rstn          ( i_rstn          ),

    // Lookup
    .i_match_vpn     ( w_data_vpn      ),
    .i_mode          ( w_tlb_mode      ),
    .i_match_asid    ( w_eff_asid      ),
    .o_ppn           ( w_dtlb_ppn      ),
    .o_perm          ( w_dtlb_perm     ),
    .o_level         ( w_dtlb_level    ),
    .o_hit           ( w_dtlb_hit      ),

    // Fill
    .i_fill_vpn      ( w_fill_vpn      ),
    .i_fill_ppn      ( w_fill_ppn      ),
    .i_fill_asid     ( w_fill_asid     ),
    .i_fill_perm     ( w_fill_perm     ),
    .i_fill_level    ( w_fill_level    ),
    .i_fill_en       ( w_fill_dtlb     ),

    // Flush
    .i_flush         ( i_flush_tlb     ),
    .i_flush_vpn     ( i_flush_vpn     ),
    .i_flush_vpn_en  ( i_flush_vpn_en  ),
    .i_flush_asid    ( i_flush_asid    ),
    .i_flush_asid_en ( i_flush_asid_en )
);

// ============================================================
// Arbitration layer
// ============================================================

friscv_l1_arbiter l1_arbiter (
    .i_clk        ( i_clk         ),
    .i_rstn       ( i_rstn        ),

    .i_inst_addr  ( i_inst_addr   ),
    .o_inst_data  ( o_inst_data   ),
    .i_inst_en    ( i_inst_en     ),
    .o_inst_wait  ( o_inst_wait   ),
    .o_inst_err   ( w_l1_inst_err ),

    .i_data_addr  ( i_data_addr   ),
    .i_data_size  ( i_data_size   ),
    .i_data_wdata ( i_data_wdata  ),
    .o_data_rdata ( o_data_rdata  ),
    .i_data_en    ( i_data_en     ),
    .i_data_wr    ( i_data_wr     ),
    .o_data_wait  ( o_data_wait   ),
    .i_amo_op     ( i_amo_op      ),
    .o_data_err   ( w_l1_data_err ),

    .o_mem_addr   ( w_grant_addr  ),
    .o_mem_size   ( w_grant_size  ),
    .o_mem_wdata  ( w_grant_wdata ),
    .i_mem_rdata  ( i_mem_rdata   ),
    .o_mem_rw     ( w_grant_rw    ),
    .i_mem_wait   ( w_stall       ),
    .i_mem_err    ( i_mem_err     ),
    .o_amo_op     ( w_grant_amo   ),
    .o_grant_inst ( w_grant_inst  ),
    .o_grant_start( w_grant_start ),
    .o_grant_start_inst( w_grant_start_inst ),
    .o_grant_held ( w_grant_held  )
);

// ============================================================
// Paging layer
// ============================================================

// Paging active when satp.MODE != 0 and not in M-mode
assign w_paging_en = (|w_eff_req_ctx.satp.mode) && (w_eff_req_ctx.mode != M_MODE);

// Arbiter is in a grant state when it drives a non-idle command
assign w_grant_active = (w_grant_rw != RW_IDLE);

assign w_grant_wr = (w_grant_rw == RW_WRITE);

always_comb begin
    w_start_req_ctx.addr     = w_grant_start_inst ? i_inst_addr : i_data_addr;
    w_start_req_ctx.satp     = i_satp;
    w_start_req_ctx.mode     = w_grant_start_inst ? i_inst_mode : i_data_mode;
    w_start_req_ctx.sum      = i_sum;
    w_start_req_ctx.mxr      = i_mxr;
    w_start_req_ctx.is_inst  = w_grant_start_inst;
    w_start_req_ctx.is_write = !w_grant_start_inst && (i_data_wr || i_data_store_like || (i_amo_op != AMO_NONE));
end

always_comb begin
    w_eff_req_ctx = w_grant_held ? r_req_ctx : w_start_req_ctx;
    w_eff_asid    = w_eff_req_ctx.satp.asid;
end

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_req_ctx <= '0;
    end else if (w_grant_start) begin
        r_req_ctx <= w_start_req_ctx;
    end
end

// TLB validity gate
vpn_t r_ivpn_q, r_dvpn_q;
// A fill/flush last cycle, the registered TLB result is stale this cycle
logic r_tlb_changed;

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_ivpn_q      <= '0;
        r_dvpn_q      <= '0;
        r_tlb_changed <= 1'b0;
    end else begin
        r_ivpn_q      <= w_inst_vpn;
        r_dvpn_q      <= w_data_vpn;
        r_tlb_changed <= w_fill_itlb | w_fill_dtlb | i_flush_tlb;
    end
end

// A request the memory has taken cannot be withdrawn, so it must not be
// translated again. An sfence.vma in between would make it a TLB miss and
// the walk would read the request's own response as its PTE.
logic  r_access_busy;
addr_t r_access_pa, w_tlate_pa;

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_access_busy <= 1'b0;
        r_access_pa   <= '0;
    end else if (!i_mem_wait) begin
        r_access_busy <= 1'b0;
    end else if (!r_access_busy && !w_walk_en && o_mem_rw != RW_IDLE) begin
        r_access_busy <= 1'b1;
        r_access_pa   <= w_tlate_pa;
    end
end

// The registered TLB output is valid for this access only when
//  1) its VPN was the one looked up last cycle and
//  2) no fill/flush last cycle changed the TLB contents
// Pending only matters under paging, a granted access whose registered translation is
// not yet valid for its own VPN must wait
logic w_tlate_valid, w_tlate_pending;
assign w_tlate_valid = !r_tlb_changed &&
                       (w_eff_req_ctx.is_inst ? (r_ivpn_q == w_inst_vpn)
                                              : (r_dvpn_q == w_data_vpn));
assign w_tlate_pending = w_paging_en && w_grant_active && !w_tlate_valid && !r_access_busy;

// TLB miss - arbiter has granted the request, paging is on, and the TLB did not hit
logic w_itlb_miss, w_dtlb_miss, w_tlb_miss;
assign w_itlb_miss = w_grant_active &&  w_eff_req_ctx.is_inst && !w_itlb_hit && w_paging_en && !w_tlate_pending && !r_access_busy;
assign w_dtlb_miss = w_grant_active && !w_eff_req_ctx.is_inst && !w_dtlb_hit && w_paging_en && !w_tlate_pending && !r_access_busy;
assign w_tlb_miss  = w_itlb_miss || w_dtlb_miss;

// PTW memory interface
addr_t w_walk_addr;
logic  w_walk_en;
data_t w_walk_rdata;
logic  w_walk_wait;
logic  w_walk_err;
logic  w_ptw_stall;

// PTW intermediate fault wires
logic  w_ptw_inst_fault, w_ptw_load_fault, w_ptw_store_fault;
addr_t w_ptw_fault_addr;

// PTW PMP
logic w_walk_req;
logic w_ptw_pmp_fault, w_ptw_access_fault;

friscv_ptw ptw (
    .i_clk           ( i_clk             ),
    .i_rstn          ( i_rstn            ),

    // Translation control
    .i_satp          ( w_eff_req_ctx.satp ),

    // Walk trigger
    .i_itlb_miss     ( w_itlb_miss       ),
    .i_dtlb_miss     ( w_dtlb_miss       ),
    .i_req_va        ( w_eff_req_ctx.addr ),
    .i_req_is_write  ( w_eff_req_ctx.is_write ),

    // PMP control
    .i_pmp_fault     ( w_ptw_pmp_fault   ),
    .o_walk_req      ( w_walk_req        ),
    .o_pmp_fault     ( w_ptw_access_fault),

    // External bus
    .o_walk_addr     ( w_walk_addr       ),
    .o_walk_en       ( w_walk_en         ),
    .i_walk_rdata    ( w_walk_rdata      ),
    .i_walk_wait     ( w_walk_wait       ),
    .i_walk_err      ( w_walk_err        ),

    // Arbiter stall
    .o_stall         ( w_ptw_stall       ),

    // TLB fill
    .o_fill_vpn      ( w_fill_vpn        ),
    .o_fill_ppn      ( w_fill_ppn        ),
    .o_fill_asid     ( w_fill_asid       ),
    .o_fill_perm     ( w_fill_perm       ),
    .o_fill_level    ( w_fill_level      ),
    .o_fill_itlb_en  ( w_fill_itlb       ),
    .o_fill_dtlb_en  ( w_fill_dtlb       ),

    // Page fault outputs
    .o_inst_fault    ( w_ptw_inst_fault  ),
    .o_load_fault    ( w_ptw_load_fault  ),
    .o_store_fault   ( w_ptw_store_fault ),
    .o_fault_addr    ( w_ptw_fault_addr  )
);

if (ENFORCE_PMP && ENFORCE_PTW_PMP) begin : gen_ptw_pmp_check
    friscv_pmp_check #(
        .PMP_ENTRIES ( PMP_ENTRIES )
    ) pmp_chk_ptw (
        .i_pa        ( w_walk_addr     ),
        .i_access_r  ( w_walk_req      ),
        .i_access_w  ( 1'b0            ),
        .i_access_x  ( 1'b0            ),
        .i_mode      ( S_MODE          ),
        .i_pmp_table ( i_pmp_table     ),
        .o_fault     ( w_ptw_pmp_fault )
    );
end else begin : gen_no_ptw_pmp_check
    assign w_ptw_pmp_fault = 1'b0;
end

// ============================================================
// Permission check (TLB hit path)
// ============================================================

logic w_perm_inst_ok, w_perm_load_ok, w_perm_store_ok;
logic w_perm_inst_fault, w_perm_load_fault, w_perm_store_fault;
logic w_perm_fault;

logic w_inst_pmp_fault, w_data_pmp_fault;
assign o_inst_pmp_fault = w_inst_pmp_fault || (w_ptw_access_fault && w_walk_en);
assign o_data_pmp_fault = w_data_pmp_fault || (w_ptw_access_fault && w_walk_en);

logic w_data_read, w_data_write;
assign w_data_read  = i_data_en && (!i_data_store_like || (i_amo_op != AMO_NONE));
assign w_data_write = i_data_en &&   i_data_store_like;

// PMP fault of the access currently granted on the bus
logic w_grant_pmp_fault;
assign w_grant_pmp_fault = w_grant_active && !r_access_busy &&
                           (w_eff_req_ctx.is_inst ? w_inst_pmp_fault : w_data_pmp_fault);

if (ENFORCE_PMP) begin : gen_pmp_check
    friscv_pmp_check #(
        .PMP_ENTRIES ( PMP_ENTRIES )
    ) pmp_chk_inst (
        .i_pa        ( w_inst_pa        ),
        .i_access_r  ( 1'b0             ),
        .i_access_w  ( 1'b0             ),
        .i_access_x  ( i_inst_en        ),
        .i_mode      ( i_inst_mode      ),
        .i_pmp_table ( i_pmp_table      ),
        .o_fault     ( w_inst_pmp_fault )
    );

    friscv_pmp_check #(
        .PMP_ENTRIES ( PMP_ENTRIES )
    ) pmp_chk_data (
        .i_pa        ( w_data_pa        ),
        .i_access_r  ( w_data_read      ),
        .i_access_w  ( w_data_write     ),
        .i_access_x  ( 1'b0             ),
        .i_mode      ( i_data_mode      ),
        .i_pmp_table ( i_pmp_table      ),
        .o_fault     ( w_data_pmp_fault )
    );
end else begin : gen_no_pmp_check
    assign w_inst_pmp_fault = 1'b0;
    assign w_data_pmp_fault = 1'b0;
end

// Instruction fetch TLB permission check
assign w_perm_inst_ok = w_itlb_perm.x &&
                        w_itlb_perm.a &&
                        ((w_eff_req_ctx.mode == U_MODE &&  w_itlb_perm.u) ||
                         (w_eff_req_ctx.mode == S_MODE && !w_itlb_perm.u));

// Load TLB permission check
assign w_perm_load_ok = (w_dtlb_perm.r || (w_eff_req_ctx.mxr && w_dtlb_perm.x)) &&
                        w_dtlb_perm.a &&
                        ((w_eff_req_ctx.mode == U_MODE &&  w_dtlb_perm.u) ||
                         (w_eff_req_ctx.mode == S_MODE && (!w_dtlb_perm.u || w_eff_req_ctx.sum)));

// Store TLB permission check
assign w_perm_store_ok = w_dtlb_perm.w &&
                         w_dtlb_perm.d &&
                         w_dtlb_perm.a &&
                         ((w_eff_req_ctx.mode == U_MODE &&  w_dtlb_perm.u) ||
                          (w_eff_req_ctx.mode == S_MODE && (!w_dtlb_perm.u || w_eff_req_ctx.sum)));

// Perm fault: paging on, arbiter granted, TLB hit, but permission denied
assign w_perm_inst_fault  = w_paging_en && w_grant_active &&  w_eff_req_ctx.is_inst                            && w_itlb_hit && !w_perm_inst_ok  && !w_tlate_pending && !r_access_busy;
assign w_perm_load_fault  = w_paging_en && w_grant_active && !w_eff_req_ctx.is_inst && !w_eff_req_ctx.is_write && w_dtlb_hit && !w_perm_load_ok  && !w_tlate_pending && !r_access_busy;
assign w_perm_store_fault = w_paging_en && w_grant_active && !w_eff_req_ctx.is_inst &&  w_eff_req_ctx.is_write && w_dtlb_hit && !w_perm_store_ok && !w_tlate_pending && !r_access_busy;
assign w_perm_fault       = w_perm_inst_fault | w_perm_load_fault | w_perm_store_fault;

// Final fault outputs: PTW structural faults OR perm faults
// PTW faults only if TLB miss, perm faults only if TLB hit - mutually exclusive
assign o_inst_fault  = w_ptw_inst_fault  | w_perm_inst_fault;
assign o_load_fault  = w_ptw_load_fault  | w_perm_load_fault;
assign o_store_fault = w_ptw_store_fault | w_perm_store_fault;
assign o_fault_addr  = (w_ptw_inst_fault | w_ptw_load_fault | w_ptw_store_fault) ? w_ptw_fault_addr : w_eff_req_ctx.addr;

// ============================================================
// PTW / arbiter bus mux
// ============================================================

// Physical address for the granted request
ppn_t w_granted_ppn;
assign w_granted_ppn = w_eff_req_ctx.is_inst ? w_itlb_ppn : w_dtlb_ppn;

addr_t w_granted_pa;
assign w_tlate_pa   = w_paging_en ? {w_granted_ppn, w_eff_req_ctx.addr[11:0]} : w_eff_req_ctx.addr;
assign w_granted_pa = r_access_busy ? r_access_pa : w_tlate_pa;

assign o_inst_err = w_l1_inst_err;
assign o_data_err = w_l1_data_err;

// PTW walk signals routed directly to/from external memory
assign w_walk_rdata = i_mem_rdata;
assign w_walk_wait  = i_mem_wait;
assign w_walk_err   = i_mem_err;

// Stall arbiter while PTW is active, memory stalls, or the registered
// translation for the granted access is not yet valid
assign w_stall = w_ptw_stall | i_mem_wait | w_tlate_pending;

// Suppress physical memory access on TLB miss (PTW takes over), perm fault,
// PMP fault, or while the translation is still not ready
assign o_mem_rw    = w_walk_en ? RW_READ :
                     (w_tlb_miss | w_perm_fault | w_grant_pmp_fault | w_tlate_pending) ? RW_IDLE :
                     w_grant_rw;

assign o_mem_addr  = w_walk_en ? w_walk_addr : w_granted_pa;

assign o_mem_size  = w_walk_en ? WIDTH_I32 : w_grant_size;
assign o_mem_wdata = w_walk_en ? '0        : w_grant_wdata;
assign o_amo_op    = w_walk_en ? AMO_NONE  : w_grant_amo;

endmodule

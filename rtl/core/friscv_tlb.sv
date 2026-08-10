// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements a fully associative TLB with a clock (second-chance) replacement policy.
 * The TLB is flushed on SFENCE.VMA instructions, with support for both global and fine-grained flushing based on VPN and ASID.
 * If ENABLE_FINE_TLB_FLUSH is not enabled, any SFENCE.VMA will flush all entries. Enabling it allows for better performance
 * but increases area significantly.
 *
 * Any matched lookup will be combinatorially output, there is no handshake for a lookup.
 * On a fill, if there is an invalid entry, it will be used. Otherwise, the clock algorithm will select a victim for replacement
 * and fill on the next posedge.
 *
 * This module does not perform any permission checks, and simply does lookups and fills.
 * A flush and a fill cannot happen in the same cycle, flush takes priority over fill.
 *
 * This module is parametrized for both 32-bit and 64-bit implementations.
 */

module friscv_tlb import friscv_pkg::*, friscv_mem_pkg::*; #(
    parameter int   ENTRY_COUNT = 32,
    // If not enabled, any sfence.vma will flush all TLB entries
    parameter logic ENABLE_FINE_TLB_FLUSH = 0
) (
    input  logic       i_clk,
    input  logic       i_rstn,

    // Lookup
    input  vpn_t       i_match_vpn,
    input  satp_mode_e i_mode,
    input  asid_t      i_match_asid,
    output ppn_t       o_ppn,
    output perm_t      o_perm,
    output pte_level_t o_level,
    output logic       o_hit,

    // Fill
    input  vpn_t       i_fill_vpn,
    input  ppn_t       i_fill_ppn,
    input  asid_t      i_fill_asid,
    input  perm_t      i_fill_perm,
    input  pte_level_t i_fill_level,
    input  logic       i_fill_en,

    // Flush
    input  logic       i_flush,
    input  vpn_t       i_flush_vpn,
    input  logic       i_flush_vpn_en,
    input  asid_t      i_flush_asid,
    input  logic       i_flush_asid_en
);

typedef struct packed {
    vpn_t       vpn;
    ppn_t       ppn;
    asid_t      asid;
    pte_level_t level;
    perm_t      perm;
} tlb_entry_t;

tlb_entry_t r_tlb [ENTRY_COUNT];

logic [ENTRY_COUNT-1:0]         r_ref;       // Clock reference bits (set on fill, cleared on sweep)
logic [$clog2(ENTRY_COUNT)-1:0] r_clock_ptr; // Clock hand position

logic                           w_any_invalid;
logic [$clog2(ENTRY_COUNT)-1:0] w_invalid_slot, w_clock_victim, w_hit_idx;

// Generate a mask that zeroes the lowest level*pn_width bits of a vpn
function automatic logic [VPN_WIDTH-1:0] vpn_mask(
    input pte_level_t level,
    input satp_mode_e mode
);
    logic [5:0] shift;
    shift = (mode == SATP_SV32) ? 6'(level * 10) : 6'(level * 9);  // 10-bit VPNs in SV32, 9-bit in others
    vpn_mask = (shift >= VPN_WIDTH) ? '0 : ~((VPN_WIDTH'(1) << shift) - 1);
endfunction : vpn_mask

// ============================================================
// Fill and flush
// ============================================================

always_ff @(posedge i_clk or negedge i_rstn) begin : tlb_fill_and_flush

    if (!i_rstn) begin

        for (int g = 0; g < ENTRY_COUNT; g++) begin : tlb_reset
            r_tlb[g] <= '0;
        end

        r_ref       <= '0;
        r_clock_ptr <= '0;

    end else begin

        // Set ref bit on hit so recently-used entries get a second chance
        if (o_hit)
            r_ref[w_hit_idx] <= 1'b1;

        if (i_flush) begin  // Global flush enable, has priority (nothing flushed if not i_flush)

            // sfence.vma rs1, rs2: VPN+ASID match, not global
            if (ENABLE_FINE_TLB_FLUSH && i_flush_vpn_en && i_flush_asid_en) begin

                for (int g = 0; g < ENTRY_COUNT; g++) begin : tlb_flush_va_asid
                    logic [VPN_WIDTH-1:0] mask;
                    logic vpn_match;

                    mask = vpn_mask(r_tlb[g].level, i_mode);
                    vpn_match = (i_flush_vpn & mask) == r_tlb[g].vpn;

                    if (vpn_match && r_tlb[g].asid == i_flush_asid && !r_tlb[g].perm.g)
                        r_tlb[g] <= '0;
                end

            // sfence.vma rs1, x0: VPN match, all ASIDs and global
            end else if (ENABLE_FINE_TLB_FLUSH && i_flush_vpn_en) begin

                for (int g = 0; g < ENTRY_COUNT; g++) begin : tlb_flush_va
                    logic [VPN_WIDTH-1:0] mask;
                    logic vpn_match;

                    mask = vpn_mask(r_tlb[g].level, i_mode);
                    vpn_match = (i_flush_vpn & mask) == r_tlb[g].vpn;

                    if (vpn_match)
                        r_tlb[g] <= '0;
                end

            // sfence.vma x0, rs2: ASID match, not global
            end else if (ENABLE_FINE_TLB_FLUSH && i_flush_asid_en) begin

                for (int g = 0; g < ENTRY_COUNT; g++) begin : tlb_flush_asid
                    if (r_tlb[g].asid == i_flush_asid && !r_tlb[g].perm.g)
                        r_tlb[g] <= '0;
                end

            // sfence.vma x0, x0: flush all
            // Fall through to here if ENABLE_FINE_TLB_FLUSH is not set.
            end else begin

                for (int g = 0; g < ENTRY_COUNT; g++) begin : tlb_flush_all
                    r_tlb[g] <= '0;
                end

            end

        end else if (i_fill_en) begin  // Insert or replace with new entry

            logic [$clog2(ENTRY_COUNT)-1:0] victim;
            logic [VPN_WIDTH-1:0] mask;

            victim = w_any_invalid ? w_invalid_slot : w_clock_victim;
            mask   = vpn_mask(i_fill_level, i_mode);

            r_tlb[victim].vpn   <= i_fill_vpn & mask;
            r_tlb[victim].ppn   <= i_fill_ppn;
            r_tlb[victim].asid  <= i_fill_asid;
            r_tlb[victim].level <= i_fill_level;
            r_tlb[victim].perm  <= i_fill_perm;
            r_ref[victim]       <= 1'b1;  // Mark newly added entry as recently used

            if (!w_any_invalid) begin
                // Clear ref bits of all entries the clock hand swept past on its way to the victim
                // Entries at distance 0 to dist_victim-1 from r_clock_ptr are cleared (not recently used)
                for (int g = 0; g < ENTRY_COUNT; g++) begin : tlb_sweep_ref
                    // 5-bit unsigned circular distances from clock_ptr to g and to victim
                    if (($clog2(ENTRY_COUNT))'(g) - r_clock_ptr < w_clock_victim - r_clock_ptr)
                        r_ref[g] <= 1'b0;
                end
                r_clock_ptr <= (w_clock_victim == ($clog2(ENTRY_COUNT))'(ENTRY_COUNT-1)) ? '0 : w_clock_victim + 1;
            end

        end

    end
end : tlb_fill_and_flush

// ============================================================
// Victim decision
// ============================================================

always_comb begin : tlb_detect_invalid_slot
    w_any_invalid = 1'b0;
    w_invalid_slot = '0;
    for (int g = 0; g < ENTRY_COUNT; g++) begin
        if (!r_tlb[g].perm.v && !w_any_invalid) begin
            w_any_invalid = 1'b1;
            w_invalid_slot = g[$clog2(ENTRY_COUNT)-1:0];
        end
    end
end

// Clock victim - first entry with r_ref=0 starting from r_clock_ptr, circular.
// If all refs are 1, defaults to r_clock_ptr.
always_comb begin : tlb_detect_clock_victim
    w_clock_victim = r_clock_ptr;
    for (int i = ENTRY_COUNT-1; i >= 0; i--) begin
        if (!r_ref[r_clock_ptr + i[$clog2(ENTRY_COUNT)-1:0]])
            w_clock_victim = r_clock_ptr + i[$clog2(ENTRY_COUNT)-1:0];
    end
end

// ============================================================
// Lookup
// ============================================================

function automatic logic [PPN_WIDTH-1:0] reconstruct_ppn(
    input logic [PPN_WIDTH-1:0] ppn,
    input logic [VPN_WIDTH-1:0] vpn,
    input pte_level_t           level,
    input satp_mode_e           mode
);
    logic [5:0] shift;
    logic [PPN_WIDTH-1:0] low_mask;

    shift = (mode == SATP_SV32) ? 6'(level * 10) : 6'(level * 9);                  // 10-bit VPNs in SV32, 9-bit in others
    low_mask = (shift >= PPN_WIDTH) ? '1 : ((PPN_WIDTH'(1) << shift) - 1);         // Keep only the lowest shift bits of vpn
    reconstruct_ppn = (ppn & ~((PPN_WIDTH'(1) << shift) - 1)) | (vpn & low_mask);  // Combine high of ppn with low of vpn
endfunction : reconstruct_ppn

ppn_t       r_ppn, w_ppn;
perm_t      r_perm, w_perm;
pte_level_t r_level, w_level;
logic       r_hit, w_hit;

always_ff @(posedge i_clk or negedge i_rstn) begin : buffer_lookup
    if (!i_rstn) begin
        r_ppn   <= '0;
        r_perm  <= '0;
        r_level <= '0;
        r_hit   <= 1'b0;
    end else begin
        r_ppn   <= w_ppn;
        r_perm  <= w_perm;
        r_level <= w_level;
        r_hit   <= w_hit;
    end
end

assign o_ppn   = r_ppn;
assign o_perm  = r_perm;
assign o_level = r_level;
assign o_hit   = r_hit;

always_comb begin
    w_ppn     = '0;
    w_perm    = '0;
    w_level   = '0;
    w_hit     = 1'b0;
    w_hit_idx = '0;

    for (int g = 0; g < ENTRY_COUNT; g++) begin : tlb_lookup
        logic [VPN_WIDTH-1:0] mask;
        logic vpn_match;

        mask      = vpn_mask(r_tlb[g].level, i_mode);
        vpn_match = (i_match_vpn & mask) == r_tlb[g].vpn;

        if (r_tlb[g].perm.v && (r_tlb[g].perm.g || i_match_asid == r_tlb[g].asid) && vpn_match) begin
            w_ppn     = reconstruct_ppn(r_tlb[g].ppn, i_match_vpn, r_tlb[g].level, i_mode);
            w_perm    = r_tlb[g].perm;
            w_level   = r_tlb[g].level;
            w_hit     = 1'b1;
            w_hit_idx = g[$clog2(ENTRY_COUNT)-1:0];
        end
    end : tlb_lookup
end

endmodule

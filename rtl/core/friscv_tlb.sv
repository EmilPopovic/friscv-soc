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

module friscv_tlb import friscv_pkg::*; #(
    parameter int unsigned EntryCount  = 32,
    // If not enabled, any sfence.vma will flush all TLB entries
    parameter bit EnableFineTlbFlush = 0
) (
    input  logic       clk_i,
    input  logic       rst_ni,

    // Lookup
    input  vpn_t       match_vpn_i,
    input  satp_mode_e mode_i,
    input  asid_t      match_asid_i,
    output ppn_t       ppn_o,
    output perm_t      perm_o,
    output logic       hit_o,

    // Fill
    input  vpn_t       fill_vpn_i,
    input  ppn_t       fill_ppn_i,
    input  asid_t      fill_asid_i,
    input  perm_t      fill_perm_i,
    input  pte_level_t fill_level_i,
    input  logic       fill_en_i,

    // Flush
    input  logic       flush_i,
    input  vpn_t       flush_vpn_i,
    input  logic       flush_vpn_en_i,
    input  asid_t      flush_asid_i,
    input  logic       flush_asid_en_i
);

if (EntryCount < 2) begin : gen_chk_entry_count
    $fatal(1, "EntryCount must be at least 2, got %0d", EntryCount);
end
if (EntryCount != (1 << $clog2(EntryCount))) begin : gen_chk_entry_pow2
    $fatal(1, "EntryCount must be a power of two, got %0d", EntryCount);
end

typedef struct packed {
    vpn_t       vpn;
    ppn_t       ppn;
    asid_t      asid;
    pte_level_t level;
    perm_t      perm;
} tlb_entry_t;

tlb_entry_t tlb [EntryCount];

logic [EntryCount-1:0]         ref_q;       // Clock reference bits (set on fill, cleared on sweep)
logic [$clog2(EntryCount)-1:0] clock_ptr_q; // Clock hand position

logic                          any_invalid;
logic [$clog2(EntryCount)-1:0] invalid_slot, clock_victim, hit_idx;

// Generate a mask that zeroes the lowest level*pn_width bits of a vpn
`pragma diagnostic push
`pragma diagnostic ignore="-Warith-op-mismatch"
function automatic logic [VPN_W-1:0] vpn_mask(
    input pte_level_t level,
    input satp_mode_e mode
);
    logic [5:0] shift;
    shift = (mode == SATP_SV32) ? 6'(level * 10) : 6'(level * 9);  // 10-bit VPNs in SV32, 9-bit in others
    return (shift >= 6'(VPN_W)) ? '0 : ~((VPN_W'(1) << shift) - 1);
endfunction
`pragma diagnostic pop

// ============================================================
// Fill and flush
// ============================================================

logic hit_d;

always_ff @(posedge clk_i or negedge rst_ni) begin

    if (!rst_ni) begin
        for (int unsigned g = 0; g < EntryCount; g++) tlb[g] <= '0;
        ref_q       <= '0;
        clock_ptr_q <= '0;

    end else begin

        // Set ref bit on hit so recently-used entries get a second chance
        if (hit_d)
            ref_q[hit_idx] <= 1'b1;

        if (flush_i) begin  // Global flush enable, has priority (nothing flushed if not flush_i)

            // sfence.vma rs1, rs2: VPN+ASID match, not global
            if (EnableFineTlbFlush && flush_vpn_en_i && flush_asid_en_i) begin

                for (int unsigned g = 0; g < EntryCount; g++) begin
                    vpn_t mask;
                    logic vpn_match;

                    mask = vpn_mask(tlb[g].level, mode_i);
                    vpn_match = (flush_vpn_i & mask) == tlb[g].vpn;

                    if (vpn_match && tlb[g].asid == flush_asid_i && !tlb[g].perm.g)
                        tlb[g] <= '0;
                end

            // sfence.vma rs1, x0: VPN match, all ASIDs and global
            end else if (EnableFineTlbFlush && flush_vpn_en_i) begin

                for (int unsigned g = 0; g < EntryCount; g++) begin
                    vpn_t mask;
                    logic vpn_match;

                    mask = vpn_mask(tlb[g].level, mode_i);
                    vpn_match = (flush_vpn_i & mask) == tlb[g].vpn;

                    if (vpn_match)
                        tlb[g] <= '0;
                end

            // sfence.vma x0, rs2: ASID match, not global
            end else if (EnableFineTlbFlush && flush_asid_en_i) begin

                for (int unsigned g = 0; g < EntryCount; g++) begin
                    if (tlb[g].asid == flush_asid_i && !tlb[g].perm.g)
                        tlb[g] <= '0;
                end

            // sfence.vma x0, x0: flush all
            // Fall through to here if EnableFineTlbFlush is not set.
            end else begin

                for (int unsigned g = 0; g < EntryCount; g++) begin
                    tlb[g] <= '0;
                end

            end

        end else if (fill_en_i) begin  // Insert or replace with new entry

            logic [$clog2(EntryCount)-1:0] victim;
            vpn_t mask;

            victim = any_invalid ? invalid_slot : clock_victim;
            mask   = vpn_mask(fill_level_i, mode_i);

            tlb[victim].vpn   <= fill_vpn_i & mask;
            tlb[victim].ppn   <= fill_ppn_i;
            tlb[victim].asid  <= fill_asid_i;
            tlb[victim].level <= fill_level_i;
            tlb[victim].perm  <= fill_perm_i;
            ref_q[victim]     <= 1'b1;  // Mark newly added entry as recently used

            if (!any_invalid) begin
                // Clear ref bits of all entries the clock hand swept past on its way to the victim
                // Entries at distance 0 to dist_victim-1 from r_clock_ptr are cleared (not recently used)
                for (int unsigned g = 0; g < EntryCount; g++) begin : tlb_sweep_ref
                    // 5-bit unsigned circular distances from clock_ptr to g and to victim
                    if (($clog2(EntryCount))'(g) - clock_ptr_q < clock_victim - clock_ptr_q)
                        ref_q[g] <= 1'b0;
                end
                clock_ptr_q <= (clock_victim == ($clog2(EntryCount))'(EntryCount-1)) ? '0 : clock_victim + 1;
            end

        end

    end
end

// ============================================================
// Victim decision
// ============================================================

always_comb begin : tlb_detect_invalid_slot
    any_invalid = 1'b0;
    invalid_slot = '0;
    for (int unsigned g = 0; g < EntryCount; g++) begin
        if (!tlb[g].perm.v && !any_invalid) begin
            any_invalid = 1'b1;
            invalid_slot = g[$clog2(EntryCount)-1:0];
        end
    end
end

// Clock victim - first entry with r_ref=0 starting from r_clock_ptr, circular.
// If all refs are 1, defaults to r_clock_ptr.
always_comb begin : tlb_detect_clock_victim
    clock_victim = clock_ptr_q;
    for (int i = EntryCount-1; i >= 0; i--) begin
        if (!ref_q[clock_ptr_q + i[$clog2(EntryCount)-1:0]])
            clock_victim = clock_ptr_q + i[$clog2(EntryCount)-1:0];
    end
end

// ============================================================
// Lookup
// ============================================================

`pragma diagnostic push
`pragma diagnostic ignore="-Warith-op-mismatch"
function automatic ppn_t reconstruct_ppn(
    input ppn_t       ppn,
    input vpn_t       vpn,
    input pte_level_t level,
    input satp_mode_e mode
);
    logic [5:0] shift;
    ppn_t low_mask;

    shift = (mode == SATP_SV32) ? 6'(level * 10) : 6'(level * 9);                      // 10-bit VPNs in SV32, 9-bit in others
    low_mask = (shift >= 6'(PPN_W)) ? '1 : ((ppn_t'(1) << shift) - 1);                 // Keep only the lowest shift bits of vpn
    reconstruct_ppn = (ppn & ~((ppn_t'(1) << shift) - 1)) | (ppn_t'(vpn) & low_mask);  // Combine high of ppn with low of vpn
endfunction : reconstruct_ppn
`pragma diagnostic pop

ppn_t       ppn_q, ppn_d;
perm_t      perm_q, perm_d;
logic       hit_q;

always_ff @(posedge clk_i or negedge rst_ni) begin : buffer_lookup
    if (!rst_ni) begin
        ppn_q   <= '0;
        perm_q  <= '0;
        hit_q   <= 1'b0;
    end else begin
        ppn_q   <= ppn_d;
        perm_q  <= perm_d;
        hit_q   <= hit_d;
    end
end

assign ppn_o   = ppn_q;
assign perm_o  = perm_q;
assign hit_o   = hit_q;

always_comb begin
    ppn_d   = '0;
    perm_d  = '0;
    hit_d   = 1'b0;
    hit_idx = '0;

    for (int unsigned g = 0; g < EntryCount; g++) begin : tlb_lookup
        vpn_t mask;
        logic vpn_match;

        mask      = vpn_mask(tlb[g].level, mode_i);
        vpn_match = (match_vpn_i & mask) == tlb[g].vpn;

        if (tlb[g].perm.v && (tlb[g].perm.g || match_asid_i == tlb[g].asid) && vpn_match) begin
            ppn_d     = reconstruct_ppn(tlb[g].ppn, match_vpn_i, tlb[g].level, mode_i);
            perm_d    = tlb[g].perm;
            hit_d     = 1'b1;
            hit_idx = g[$clog2(EntryCount)-1:0];
        end
    end : tlb_lookup
end

endmodule

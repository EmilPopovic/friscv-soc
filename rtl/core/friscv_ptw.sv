// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
//
// Version info is listed in friscv_pkg.sv

/*
 * This module implements the page table walker (PTW) for the FRISC-V MMU.
 * It performs multi-level page table walks on demand when TLB misses occur, and fills the TLBs with the results.
 * It also detects page faults and reports them to the pipeline control for proper handling.
 *
 * The PTW is a state machine that interacts with an external memory interface to read PTEs.
 * It supports both SV32 and SV39+ page table formats, and can handle variable page sizes and superpages.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_ptw (
    input  logic       i_clk,
    input  logic       i_rstn,

    // Translation control
    input  satp_t      i_satp,

    // Walk trigger
    input  logic       i_itlb_miss,
    input  logic       i_dtlb_miss,
    input  addr_t      i_req_va,
    input  logic       i_req_is_write,

    // PMP control
    input  logic       i_pmp_fault,
    output logic       o_walk_req,
    output logic       o_pmp_fault,

    // External bus
    output addr_t      o_walk_addr,
    output logic       o_walk_en,
    input  data_t      i_walk_rdata,
    input  logic       i_walk_wait,
    input  logic       i_walk_err,

    // Arbiter stall
    output logic       o_stall,

    // TLB fill
    output vpn_t       o_fill_vpn,
    output ppn_t       o_fill_ppn,
    output asid_t      o_fill_asid,
    output perm_t      o_fill_perm,
    output pte_level_t o_fill_level,
    output logic       o_fill_itlb_en,
    output logic       o_fill_dtlb_en,

    // Page fault outputs
    output logic       o_inst_fault,
    output logic       o_load_fault,
    output logic       o_store_fault,
    output addr_t      o_fault_addr
);

// Semantic states
typedef enum logic [2:0] {
    S_IDLE,
    S_READ,
    S_DECODE,
    S_FILL,
    S_PAGE_FAULT,
    S_PMP_FAULT
} state_e;

state_e r_state, w_next_state;

typedef struct packed {
    ppn_t       ppn;
    logic [1:0] reserved;  // [9:8] Reserved
    perm_t      perm;
} pte_t;

pte_t r_pte;

logic w_start_walk;
assign w_start_walk = satp_mode_e'(i_satp.mode) != SATP_BARE
                      && r_state == S_IDLE
                      && (i_itlb_miss || i_dtlb_miss);

// ============================================================
// Capture inputs
// ============================================================

satp_t r_satp;
logic  r_itlb_miss, r_dtlb_miss;
addr_t r_req_va;
logic  r_req_is_write;

always_ff @(posedge i_clk) begin : capture_inputs
    if (!i_rstn) begin
        r_satp         <= '0;
        r_itlb_miss    <= 1'b0;
        r_dtlb_miss    <= 1'b0;
        r_req_va       <= '0;
        r_req_is_write <= 1'b0;
    end else if (w_start_walk) begin
        r_satp         <= i_satp;
        r_itlb_miss    <= i_itlb_miss;
        r_dtlb_miss    <= i_dtlb_miss;
        r_req_va       <= i_req_va;
        r_req_is_write <= i_req_is_write;
    end
end : capture_inputs

// ============================================================
// Determine mode geometry
// ============================================================

logic [2:0] r_max_level, w_max_level;
logic       r_is_wide_vpn, w_is_wide_vpn;  // 1: 10-bit VPN fields (SV32), 0: 9-bit (SV39+)
logic       r_is_wide_pte, w_is_wide_pte;  // 1: 8-byte PTEs (SV39+), 0: 4-byte (SV32)

always_ff @(posedge i_clk) begin : geometry_capture
    if (!i_rstn) begin
        r_max_level   <= 3'b1;
        r_is_wide_vpn <= 1'b0;
        r_is_wide_pte <= 1'b0;
    end else if (w_start_walk) begin
        r_max_level   <= w_max_level;
        r_is_wide_vpn <= w_is_wide_vpn;
        r_is_wide_pte <= w_is_wide_pte;
    end
end : geometry_capture

always_comb begin : geometry_decode
    w_is_wide_vpn = 1'b0;
    w_is_wide_pte = 1'b1;

    case (satp_mode_e'(i_satp.mode))
        SATP_SV32: begin
            w_max_level   = 3'd1;
            w_is_wide_vpn = 1'b1;
            w_is_wide_pte = 1'b0;
        end
        SATP_SV39: w_max_level = 3'd2;
        SATP_SV48: w_max_level = 3'd3;
        SATP_SV57: w_max_level = 3'd4;
        SATP_BARE:  w_max_level = 3'd0;
        default:   w_max_level = 3'd1;
    endcase
end : geometry_decode

// ============================================================
// State machine
// ============================================================

always_ff @(posedge i_clk) begin : transition_state
    if (!i_rstn) r_state <= S_IDLE;
    else         r_state <= w_next_state;
end

// r_level is the level of the PTE currently being read or decoded
logic [2:0] r_level;
logic       w_descend;

always_ff @(posedge i_clk) begin : pte_capture
    if (!i_rstn) begin
        r_pte   <= '0;
        r_level <= 3'b0;
    end else if (w_start_walk) begin
        r_pte <= '{
            ppn: i_satp.ppn,
            reserved: 2'b0,
            perm: '{
                d: 1'b0, a: 1'b0, g: 1'b0, u: 1'b0,
                x: 1'b0, w: 1'b0, r: 1'b0, v: 1'b1
            }
        };
        r_level <= w_max_level;
    end else if (r_state == S_READ && !i_walk_wait) begin
        r_pte <= pte_t'(i_walk_rdata);
    end else if (w_descend) begin
        r_level <= r_level - 1;
    end
end : pte_capture

// ============================================================
// Effective walk inputs
// ============================================================

// o_walk_en is asserted one cycle before entering S_READ so that the downstream
// has time to assert i_walk_wait before we sample it
// The walk address must therefore be valid during that pre-read cycle

ppn_t       w_eff_ppn;
addr_t      w_eff_va;
logic [2:0] w_eff_level;
logic       w_eff_wide_vpn;
logic       w_eff_wide_pte;

assign w_eff_ppn      = w_start_walk ? ppn_t'(i_satp.ppn) : r_pte.ppn;
assign w_eff_va       = w_start_walk ? i_req_va           : r_req_va;
assign w_eff_wide_vpn = w_start_walk ? w_is_wide_vpn      : r_is_wide_vpn;
assign w_eff_wide_pte = w_start_walk ? w_is_wide_pte      : r_is_wide_pte;

always_comb begin : eff_level_select
    if (w_start_walk)
        w_eff_level = w_max_level;
    else if (r_state == S_DECODE && w_descend)
        w_eff_level = r_level - 3'd1;
    else
        w_eff_level = r_level;
end : eff_level_select

// ============================================================
// VPN field extraction
// ============================================================

logic [9:0] w_vpn_idx;

always_comb begin : vpn_extract
    w_vpn_idx = '0;
    if (w_eff_wide_vpn) begin  // SV32: 10-bit VPN fields
        case (w_eff_level)
            3'd1:    w_vpn_idx = w_eff_va[31:22];  // VPN[1]
            default: w_vpn_idx = w_eff_va[21:12];  // VPN[0]
        endcase
    end else begin  // SV39/48/57: 9-bit VPN fields
        w_vpn_idx = {1'b0, w_eff_va[12 + 9*w_eff_level[2:0] +: 9]};
    end
end : vpn_extract

// PTE address = base_ppn * PAGESIZE | VPN[level] * PTE_SIZE
// The PPN base has zeros in [11:0] and the VPN offset fits within 12 bits, so | is safe.
assign o_walk_addr = addr_t'({w_eff_ppn, 12'b0}) |
                     (w_eff_wide_pte ? addr_t'({w_vpn_idx, 3'b0})
                                     : addr_t'({w_vpn_idx, 2'b0}));

// ============================================================
// Transition logic
// ============================================================

always_comb begin : transition_logic
    w_next_state = r_state;
    w_descend    = 1'b0;

    o_walk_en  = 1'b0;
    o_walk_req = 1'b0;
    o_stall    = 1'b1;

    o_fill_vpn     = '0;
    o_fill_ppn     = '0;
    o_fill_asid    = '0;
    o_fill_perm    = '0;
    o_fill_level   = '0;
    o_fill_itlb_en = 1'b0;
    o_fill_dtlb_en = 1'b0;

    o_inst_fault  = 1'b0;
    o_load_fault  = 1'b0;
    o_store_fault = 1'b0;
    o_fault_addr  = '0;
    o_pmp_fault   = 1'b0;

    case (r_state)

        S_IDLE: begin
            o_stall    = 1'b0;
            o_walk_req = 1'b1;
            if (w_start_walk && !i_pmp_fault) begin
                // Assert walk_en now with the effective address
                // Registers capture at posedge, so in S_READ the address is unchanged
                // and i_walk_wait already asserted
                // Do not start the walk on a PMP fault
                o_walk_en    = 1'b1;
                o_stall      = 1'b1;
                w_next_state = S_READ;
            end
        end

        S_READ: begin
            o_walk_req = 1'b1;
            o_walk_en  = 1'b1;
            if (!i_walk_wait && i_walk_err) begin
                o_stall      = 1'b0;
                w_next_state = S_IDLE;
            end else if (!i_walk_wait) begin
                w_next_state = S_DECODE;
            end
        end

        S_DECODE: begin
            if (!r_pte.perm.v || (r_pte.perm.w && !r_pte.perm.r)) begin
                // Invalid PTE
                w_next_state = S_PAGE_FAULT;
            end else if (r_pte.perm.r || r_pte.perm.x) begin
                // Leaf PTE, fill TLB and let requester retry
                // Fault if misaligned superpage
                w_next_state = (r_level != '0 && r_pte.ppn[9:0] != 10'b0) ? S_PAGE_FAULT : S_FILL;
            end else begin
                // Non-leaf PTE
                if (r_pte.perm.d || r_pte.perm.a || r_pte.perm.u) begin
                    // Non-leaf with D/A/U set
                    w_next_state = S_PAGE_FAULT;
                end else if (r_level == '0) begin
                    // Non-leaf at last level, walk exhausted
                    w_next_state = S_PAGE_FAULT;
                end else begin
                    // Non-leaf, descend, assert walk_en now with the next-level address
                    o_walk_req = 1'b1;
                    w_descend    = 1'b1;
                    if (!i_pmp_fault) begin
                        o_walk_en    = 1'b1;
                        w_next_state = S_READ;
                    end else begin
                        // Stop walk if descended level gives PMP fault
                        w_next_state = S_PMP_FAULT;
                    end
                end
            end
        end

        S_FILL: begin
            o_fill_vpn     = vpn_t'(r_req_va >> 12);
            o_fill_ppn     = r_pte.ppn;
            o_fill_asid    = r_satp.asid;
            o_fill_perm    = r_pte.perm;
            o_fill_level   = pte_level_t'(r_level);
            o_fill_itlb_en = r_itlb_miss;
            o_fill_dtlb_en = r_dtlb_miss;
            w_next_state   = S_IDLE;
        end

        // Release stall so the pipeline can capture the fault
        S_PAGE_FAULT: begin
            o_stall       = 1'b0;
            o_inst_fault  = r_itlb_miss;
            o_load_fault  = r_dtlb_miss && !r_req_is_write;
            o_store_fault = r_dtlb_miss &&  r_req_is_write;
            o_fault_addr  = r_req_va;
            w_next_state  = S_IDLE;
        end

        S_PMP_FAULT: begin
            o_stall      = 1'b0;
            o_pmp_fault  = 1'b1;
            w_next_state = S_IDLE;
        end

        default: ;

    endcase
end : transition_logic

endmodule

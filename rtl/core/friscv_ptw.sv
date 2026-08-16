// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the page table walker (PTW) for the FRISC-V MMU.
 * It performs multi-level page table walks on demand when TLB misses occur, and fills the TLBs with the results.
 * It also detects page faults and reports them to the pipeline control for proper handling.
 *
 * The PTW is a state machine that interacts with an external memory interface to read PTEs.
 * It supports both SV32 and SV39+ page table formats, and can handle variable page sizes and superpages.
 */

module friscv_ptw import friscv_pkg::*; (
    input  logic       clk_i,
    input  logic       rst_ni,

    // Translation control
    input  satp_t      satp_i,

    // Walk trigger
    input  logic       itlb_miss_i,
    input  logic       dtlb_miss_i,
    input  addr_t      req_va_i,
    input  logic       req_is_write_i,

    // PMP control
    input  logic       pmp_fault_i,
    output logic       walk_req_o,
    output logic       pmp_fault_o,

    // External bus
    output addr_t      walk_addr_o,
    output logic       walk_en_o,
    input  data_t      walk_rdata_i,
    input  logic       walk_wait_i,
    input  logic       walk_err_i,

    // Arbiter stall
    output logic       stall_o,

    // TLB fill
    output vpn_t       fill_vpn_o,
    output ppn_t       fill_ppn_o,
    output asid_t      fill_asid_o,
    output perm_t      fill_perm_o,
    output pte_level_t fill_level_o,
    output logic       fill_itlb_en_o,
    output logic       fill_dtlb_en_o,

    // Page fault outputs
    output logic       inst_fault_o,
    output logic       load_fault_o,
    output logic       store_fault_o,
    output addr_t      fault_addr_o
);

// Semantic states
typedef enum logic [2:0] {
    StIdle,
    StRead,
    StDecode,
    StFill,
    StPageFault,
    StPmpFault
} state_e;

state_e state_q, state_d;

typedef struct packed {
    ppn_t       ppn;
    logic [1:0] reserved;  // [9:8] Reserved
    perm_t      perm;
} pte_t;

pte_t pte_q;

logic start_walk;
assign start_walk = satp_mode_e'(satp_i.mode) != SATP_BARE
                    && state_q == StIdle
                    && (itlb_miss_i || dtlb_miss_i);

// ============================================================
// Capture inputs
// ============================================================

satp_t satp_q;
logic  itlb_miss_q, dtlb_miss_q;
addr_t req_va_q;
logic  req_is_write_q;

always_ff @(posedge clk_i or negedge rst_ni) begin : capture_inputs
    if (!rst_ni) begin
        satp_q         <= '0;
        itlb_miss_q    <= 1'b0;
        dtlb_miss_q    <= 1'b0;
        req_va_q       <= '0;
        req_is_write_q <= 1'b0;
    end else if (start_walk) begin
        satp_q         <= satp_i;
        itlb_miss_q    <= itlb_miss_i;
        dtlb_miss_q    <= dtlb_miss_i;
        req_va_q       <= req_va_i;
        req_is_write_q <= req_is_write_i;
    end
end : capture_inputs

// ============================================================
// Determine mode geometry
// ============================================================

logic [2:0] max_level;
logic       is_wide_vpn_q, is_wide_vpn_d;  // 1: 10-bit VPN fields (SV32), 0: 9-bit (SV39+)
logic       is_wide_pte_q, is_wide_pte_d;  // 1: 8-byte PTEs (SV39+), 0: 4-byte (SV32)

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        is_wide_vpn_q <= 1'b0;
        is_wide_pte_q <= 1'b0;
    end else if (start_walk) begin
        is_wide_vpn_q <= is_wide_vpn_d;
        is_wide_pte_q <= is_wide_pte_d;
    end
end

always_comb begin
    is_wide_vpn_d = 1'b0;
    is_wide_pte_d = 1'b1;

    unique case (satp_mode_e'(satp_i.mode))
        SATP_SV32: begin
            max_level   = 3'd1;
            is_wide_vpn_d = 1'b1;
            is_wide_pte_d = 1'b0;
        end
        SATP_SV39: max_level = 3'd2;
        SATP_SV48: max_level = 3'd3;
        SATP_SV57: max_level = 3'd4;
        SATP_BARE: max_level = 3'd0;
        default:   max_level = 3'd1;
    endcase
end

// ============================================================
// State machine
// ============================================================

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= StIdle;
    else         state_q <= state_d;
end

// r_level is the level of the PTE currently being read or decoded
logic [2:0] r_level;
logic       descend;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        pte_q   <= '0;
        r_level <= 3'b0;
    end else if (start_walk) begin
        pte_q <= '{
            ppn: satp_i.ppn,
            reserved: 2'b0,
            perm: '{
                d: 1'b0, a: 1'b0, g: 1'b0, u: 1'b0,
                x: 1'b0, w: 1'b0, r: 1'b0, v: 1'b1
            }
        };
        r_level <= max_level;
    end else if (state_q == StRead && !walk_wait_i) begin
        pte_q <= pte_t'(walk_rdata_i);
    end else if (descend) begin
        r_level <= r_level - 1;
    end
end

// ============================================================
// Effective walk inputs
// ============================================================

// o_walk_en is asserted one cycle before entering StRead so that the downstream
// has time to assert i_walk_wait before we sample it
// The walk address must therefore be valid during that pre-read cycle

ppn_t       eff_ppn;
addr_t      eff_va;
logic [2:0] eff_level;
logic       eff_wide_vpn;
logic       eff_wide_pte;

assign eff_ppn      = start_walk ? satp_i.ppn    : pte_q.ppn;
assign eff_va       = start_walk ? req_va_i      : req_va_q;
assign eff_wide_vpn = start_walk ? is_wide_vpn_d : is_wide_vpn_q;
assign eff_wide_pte = start_walk ? is_wide_pte_d : is_wide_pte_q;

always_comb begin
    if (start_walk)
        eff_level = max_level;
    else if (state_q == StDecode && descend)
        eff_level = r_level - 3'd1;
    else
        eff_level = r_level;
end

// ============================================================
// VPN field extraction
// ============================================================

logic [9:0] vpn_idx;

always_comb begin
    vpn_idx = '0;
    if (eff_wide_vpn) begin  // SV32: 10-bit VPN fields
        if (eff_level == 3'd1)
            vpn_idx = eff_va[31:22];  // VPN[1]
        else
            vpn_idx = eff_va[21:12];  // VPN[0]
    end else begin  // SV39/48/57: 9-bit VPN fields
        vpn_idx = {1'b0, eff_va[12 + 9*int'(eff_level[2:0]) +: 9]};
    end
end

// PTE address = base_ppn * PAGESIZE | VPN[level] * PTE_SIZE
// The PPN base has zeros in [11:0] and the VPN offset fits within 12 bits, so | is safe.
assign walk_addr_o = addr_t'({eff_ppn[PA_PPN_W-1:0], 12'b0}) |
                     (eff_wide_pte ? addr_t'({vpn_idx, 3'b0})
                                     : addr_t'({vpn_idx, 2'b0}));

logic ppn_oob;
assign ppn_oob = |eff_ppn[PPN_W-1:PA_PPN_W];

// ============================================================
// Transition logic
// ============================================================

always_comb begin
    state_d = state_q;
    descend = 1'b0;

    walk_en_o  = 1'b0;
    walk_req_o = 1'b0;
    stall_o    = 1'b1;

    fill_vpn_o     = '0;
    fill_ppn_o     = '0;
    fill_asid_o    = '0;
    fill_perm_o    = '0;
    fill_level_o   = '0;
    fill_itlb_en_o = 1'b0;
    fill_dtlb_en_o = 1'b0;

    inst_fault_o  = 1'b0;
    load_fault_o  = 1'b0;
    store_fault_o = 1'b0;
    fault_addr_o  = '0;
    pmp_fault_o   = 1'b0;

    case (state_q)

        StIdle: begin
            stall_o    = 1'b0;
            walk_req_o = 1'b1;
            if (start_walk && !pmp_fault_i && !ppn_oob) begin
                // Assert walk_en now with the effective address
                // Registers capture at posedge, so in StRead the address is unchanged
                // and walk_wait_i already asserted
                // Do not start the walk on a PMP fault
                walk_en_o = 1'b1;
                stall_o   = 1'b1;
                state_d   = StRead;
            end else if (start_walk) begin
                stall_o = 1'b1;
                state_d = StPmpFault;
            end
        end

        StRead: begin
            walk_req_o = 1'b1;
            walk_en_o  = 1'b1;
            if (!walk_wait_i && walk_err_i) begin
                stall_o      = 1'b0;
                state_d = StIdle;
            end else if (!walk_wait_i) begin
                state_d = StDecode;
            end
        end

        StDecode: begin
            if (!pte_q.perm.v || (pte_q.perm.w && !pte_q.perm.r)) begin
                // Invalid PTE
                state_d = StPageFault;
            end else if (pte_q.perm.r || pte_q.perm.x) begin
                // Leaf PTE, fill TLB and let requester retry
                // Fault if misaligned superpage or if the frame is out of reach.
                state_d = (r_level != '0 && pte_q.ppn[9:0] != 10'b0) ? StPageFault :
                          ppn_oob ? StPmpFault : StFill;
            end else begin
                // Non-leaf PTE
                if (pte_q.perm.d || pte_q.perm.a || pte_q.perm.u) begin
                    // Non-leaf with D/A/U set
                    state_d = StPageFault;
                end else if (r_level == '0) begin
                    // Non-leaf at last level, walk exhausted
                    state_d = StPageFault;
                end else begin
                    // Non-leaf, descend, assert walk_en now with the next-level address
                    walk_req_o = 1'b1;
                    descend    = 1'b1;
                    if (!pmp_fault_i && !ppn_oob) begin
                        walk_en_o = 1'b1;
                        state_d   = StRead;
                    end else begin
                        // Stop walk if the descended level is PMP denied or unreachable
                        state_d = StPmpFault;
                    end
                end
            end
        end

        StFill: begin
            fill_vpn_o     = vpn_t'(req_va_q >> 12);
            fill_ppn_o     = pte_q.ppn;
            fill_asid_o    = satp_q.asid;
            fill_perm_o    = pte_q.perm;
            fill_level_o   = pte_level_t'(r_level);
            fill_itlb_en_o = itlb_miss_q;
            fill_dtlb_en_o = dtlb_miss_q;
            state_d        = StIdle;
        end

        // Release stall so the pipeline can capture the fault
        StPageFault: begin
            stall_o       = 1'b0;
            inst_fault_o  = itlb_miss_q;
            load_fault_o  = dtlb_miss_q && !req_is_write_q;
            store_fault_o = dtlb_miss_q &&  req_is_write_q;
            fault_addr_o  = req_va_q;
            state_d       = StIdle;
        end

        StPmpFault: begin
            stall_o     = 1'b0;
            pmp_fault_o = 1'b1;
            state_d     = StIdle;
        end

        default: state_d = StIdle;

    endcase
end

endmodule

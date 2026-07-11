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
 * This module implements a combinatorial PMP checker.
 * If either of i_access_r/w/x is set, o_fault will be asserted if that access
 * is not allowed as per i_pmp_table.
 * If no i_access_* is set, o_fault will never assert.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_pmp_check (
    input  addr_t      i_pa,
    input  logic       i_access_r,
    input  logic       i_access_w,
    input  logic       i_access_x,
    input  mode_e      i_mode,
    input  pmp_table_t i_pmp_table,
    output logic       o_fault
);

// The two lowest bits are not used for PMP matching
addr_t w_aligned_pa;
assign w_aligned_pa = i_pa >> 2;

function automatic logic fault_for_cfg(pmp_cfg_t cfg);
    if (cfg.l || (i_mode != M_MODE))
        // If L set (even in M-mode), or not in M-mode, enforce access type
        fault_for_cfg = (i_access_r && !cfg.r) ||
                        (i_access_w && !cfg.w) ||
                        (i_access_x && !cfg.x);
    else
        // L is not set and in M-mode, allow (no fault)
        fault_for_cfg = 1'b0;
endfunction

// Stage 1: compute every entry's address match in parallel
logic [PMP_ENTRIES-1:0] w_match;

always_comb begin
    w_match = '0;
    for (int i = 0; i < PMP_ENTRIES; i++) begin
        automatic pmp_entry_t entry     = i_pmp_table[i];
        automatic addr_t      prev_addr = (i > 0) ? i_pmp_table[i-1].addr : '0;
        automatic addr_t      cmp_mask  = ~entry.addr ^ (~entry.addr + 1'b1);
        case (entry.cfg.a)
            // Top of range: pmpaddr[i-1] <= pa < pmpaddr[i]
            PMP_TOR:   w_match[i] = (prev_addr <= w_aligned_pa) && (w_aligned_pa < entry.addr);
            // Naturally aligned four-byte region
            PMP_NA4:   w_match[i] = (w_aligned_pa == entry.addr);
            // Naturally aligned power-of-two region (>= 8 bytes)
            PMP_NAPOT: w_match[i] = ((w_aligned_pa & cmp_mask) == (entry.addr & cmp_mask));
            // Null region (disabled)
            PMP_OFF:   w_match[i] = 1'b0;
            default:   w_match[i] = 1'b0;
        endcase
    end
end

// Stage 2: priority-encode
always_comb begin
    o_fault = 1'b0;
    if (i_access_r || i_access_w || i_access_x) begin
        o_fault = (i_mode != M_MODE);
        for (int i = PMP_ENTRIES-1; i >= 0; i--)
            if (w_match[i]) o_fault = fault_for_cfg(i_pmp_table[i].cfg);
    end
end

endmodule

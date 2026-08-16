// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements a combinatorial PMP checker.
 * If either of i_access_r/w/x is set, o_fault will be asserted if that access
 * is not allowed as per i_pmp_table.
 * If no i_access_* is set, o_fault will never assert.
 */

module friscv_pmp_check import friscv_pkg::*; #(
    parameter int unsigned PmpEntries = 8
) (
    input  addr_t                        pa_i,
    input  logic                         access_r_i,
    input  logic                         access_w_i,
    input  logic                         access_x_i,
    input  mode_e                        mode_i,
    input  pmp_entry_t [PmpEntries-1:0]  pmp_table_i,
    output logic                         fault_o
);

// The two lowest bits are not used for PMP matching
addr_t aligned_pa;
assign aligned_pa = pa_i >> 2;

function automatic logic fault_for_cfg(pmp_cfg_t cfg);
    if (cfg.l || (mode_i != M_MODE))
        // If L set (even in M-mode), or not in M-mode, enforce access type
        return (access_r_i && !cfg.r) ||
               (access_w_i && !cfg.w) ||
               (access_x_i && !cfg.x);
    else
        // L is not set and in M-mode, allow (no fault)
        return 1'b0;
endfunction

// Stage 1: compute every entry's address match in parallel
logic [PmpEntries-1:0] match;

always_comb begin
    match = '0;
    for (int unsigned i = 0; i < PmpEntries; i++) begin
        automatic pmp_entry_t entry     = pmp_table_i[i];
        automatic addr_t      prev_addr = (i > 0) ? pmp_table_i[i-1].addr : '0;
        automatic addr_t      cmp_mask  = ~(entry.addr ^ (~entry.addr + 1'b1));
        unique case (entry.cfg.a)
            // Top of range: pmpaddr[i-1] <= pa < pmpaddr[i]
            PMP_TOR:   match[i] = (prev_addr <= aligned_pa) && (aligned_pa < entry.addr);
            // Naturally aligned four-byte region
            PMP_NA4:   match[i] = (aligned_pa == entry.addr);
            // Naturally aligned power-of-two region (>= 8 bytes)
            PMP_NAPOT: match[i] = ((aligned_pa & cmp_mask) == (entry.addr & cmp_mask));
            // Null region (disabled)
            PMP_OFF:   match[i] = 1'b0;
            default:   match[i] = 1'b0;
        endcase
    end
end

// Stage 2: priority-encode
always_comb begin
    fault_o = 1'b0;
    if (access_r_i || access_w_i || access_x_i) begin
        fault_o = (mode_i != M_MODE);
        for (int i = PmpEntries-1; i >= 0; i--)
            if (match[i]) fault_o = fault_for_cfg(pmp_table_i[i].cfg);
    end
end

endmodule

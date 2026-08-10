// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the Control and Status Register file of the FRISC-V core. It is responsible for:
 * - Storing all architectural CSR state, including the PMP table and performance counters
 * - Serving CSR reads for the ID stage and CSR writes retiring from the WB stage
 * - Exposing CSR state to the trap controller, decoder and MMU
 * - Generating the effective STIP/SEIP pending bits (Sstc timer and external pin sources)
 *
 * The CSR file contains no trap logic. Trap detection, prioritization and privilege mode tracking live in
 * friscv_trap_controller, which commits trap and xRET state changes here through a command interface:
 * trap_csr_en_in selects capture of the pre-resolved epc/cause/tval into the debug, S-mode or M-mode trap
 * CSRs, and mret/sret_commit_in perform the mstatus stack pops. trap_in and dret_commit_in only inhibit
 * the retiring CSR write on those cycles.
 */

module friscv_csr_file import friscv_pkg::*, friscv_mem_pkg::*; #(
    parameter int unsigned HART_ID = 0,

    parameter logic ENFORCE_PMP = 0,
    parameter int   PMP_ENTRIES = 64,
    parameter int   PMP_USABLE  = 64,

    parameter logic ENABLE_MUL = 1,
    parameter logic ENABLE_DIV = 1,
    parameter logic ENABLE_EXTENSION_A = 1
) (
    input  logic        clk_in,
    input  logic        rst_n_in,

    // Hart state from the trap controller
    input  mode_e       mode_in,
    input  logic        debug_mode_in,

    // CSR read
    input  csr_addr_e   selected_csr,
    output data_t       csr_out,
    output logic        csr_not_implemented,

    // CSR write from WB
    input  csr_addr_e   csr_sel_in,
    input  logic        csr_en_in,
    input  data_t       csr_data_in,
    input  logic        instr_ret_in,

    // Trap commit commands from the trap controller
    input  logic        trap_in,           // Trap redirect this cycle, inhibits the retiring CSR write
    input  logic        trap_csr_en_in,    // Capture trap state into CSRs this cycle
    input  logic        trap_to_debug_in,  // Debug entry, write dpc/dcsr instead of xepc/xcause
    input  logic        trap_to_s_in,      // Delegated, write sepc/scause/stval instead of M equivalents
    input  addr_t       trap_epc_in,
    input  data_t       trap_cause_in,
    input  data_t       trap_tval_in,
    input  mode_e       trap_mode_in,      // Privilege mode the trap originated from (for mpp/spp)
    input  logic [2:0]  dcsr_cause_in,     // Debug entry cause for dcsr.cause
    input  logic        mret_commit_in,
    input  logic        sret_commit_in,
    input  logic        dret_commit_in,

    // CSR state to the trap controller
    output mstatus_t    mstatus_out,
    output addr_t       mtvec_out,
    output addr_t       stvec_out,
    output data_t       medeleg_out,
    output data_t       mideleg_out,
    output data_t       mie_out,
    output dcsr_t       dcsr_out,
    output addr_t       dpc_out,
    output addr_t       sepc_out,
    output addr_t       mepc_out,
    output logic        ssip_out,
    output logic        stip_eff_out,
    output logic        seip_eff_out,

    // Interrupt pending inputs
    input  logic        msip_in,
    input  logic        mtip_in,
    input  logic        meip_in,
    input  logic        seip_in,

    // Counter/Timer
    input  mtime_t      mtime_in,
    output data_t       mcounteren_out,
    output data_t       scounteren_out,

    // Memory protection
    output pmp_entry_t [PMP_ENTRIES-1:0] pmp_table_out,

    // To MMU
    output satp_t       satp_out,
    output logic        sum_out,
    output logic        mxr_out,
    output mode_e       data_mode_out
);

// CSR file definition
// Read-only CSRs are not stored here, they are hardwired in the read block
typedef struct packed {
    // Supervisor Interrupt Pending
    logic ssip;
    logic stip;
    logic seip;

    // Supervisor Trap Setup
    data_t scounteren;
    addr_t stvec;
    data_t senvcfg;

    // Supervisor Trap Handling
    data_t sscratch;
    addr_t sepc;
    data_t scause;
    inst_t stval;

    // Supervisor Timer (Sstc)
    data_t stimecmp;
    data_t stimecmph;

    // Supervisor Protection and Translation
    satp_t satp;

    // Machine Information Registers
    // Hardwired in read block

    // Machine Trap Setup
    mstatus_t mstatus;
    data_t medeleg;
    data_t mideleg;
    data_t mie;
    addr_t mtvec;
    data_t mcounteren;

    // Core Debug Registers
    dcsr_t dcsr;
    addr_t dpc;
    data_t dscratch0;
    data_t dscratch1;

    // Machine Trap Handling
    data_t mscratch;
    addr_t mepc;
    data_t mcause;
    inst_t mtval;

    // Machine Environment Configuration
    data_t menvcfg;
    data_t menvcfgh;

    // Machine Counter/Timers
    logic [63:0] mcycle;
    logic [63:0] minstret;

    // Machine Counter Setup
    data_t mcountinhibit;
} csr_file_t;

csr_file_t csr;

assign mstatus_out    = csr.mstatus;
assign mtvec_out      = csr.mtvec;
assign stvec_out      = csr.stvec;
assign mcounteren_out = csr.mcounteren;
assign scounteren_out = csr.scounteren;
assign medeleg_out    = csr.medeleg;
assign mideleg_out    = csr.mideleg;
assign mie_out        = csr.mie;
assign dpc_out        = csr.dpc;
assign sepc_out       = csr.sepc;
assign mepc_out       = csr.mepc;
assign dcsr_out       = csr.dcsr;

assign ssip_out = csr.ssip;

// Registered output of 64-bit compare
logic stimecmp_result;
always_ff @(posedge clk_in or negedge rst_n_in) begin
    if (!rst_n_in) stimecmp_result <= 1'b0;
    else           stimecmp_result <= (mtime_in >= {csr.stimecmph, csr.stimecmp});
end

// STIP has two sources:
//  1) Hardware: when mtime >= stimecmp, and menvcfgh[31] enables this behavior
//  2) Software: when M-mode or S-mode writes to the STIP bit in mip
// stip_eff is the effective STIP value taking both into account. SEIP likewise
// combines the mip bit with the external pin.
logic stip_eff, seip_eff;
assign stip_eff = csr.stip || (csr.menvcfgh[31] && stimecmp_result);
assign seip_eff = csr.seip || seip_in;

assign stip_eff_out = stip_eff;
assign seip_eff_out = seip_eff;

// Read-only status of CSR being written back
// This is to protect the state of read-only CSRs, but should never be true
// as writes to read-only CSRs will be decoded as illegal instructions and trap.
logic wb_csr_ro;
assign wb_csr_ro = csr_sel_in[11:10] == 2'b11;

// ============================================================
// Physical Memory Protection
// ============================================================

pmp_entry_t [PMP_ENTRIES-1:0] pmp_table;
assign pmp_table_out = pmp_table;

// Pack a pmp_cfg_t struct into its 8-bit pmpcfg byte
function automatic logic [7:0] pmpcfg_of(pmp_cfg_t pmp_cfg);
    pmpcfg_of = {pmp_cfg.l, 2'b00, pmp_cfg.a, pmp_cfg.x, pmp_cfg.w, pmp_cfg.r};
endfunction

// Decode an 8-bit pmpcfg byte into a pmp_cfg_t struct
function automatic pmp_cfg_t cfg_from_byte(logic [7:0] b);
    if (b[1] && !b[0]) cfg_from_byte = '{l: b[7], a: pmp_mode_e'(b[4:3]), x: 1'b0, w: 1'b0, r: 1'b0};
    else               cfg_from_byte = '{l: b[7], a: pmp_mode_e'(b[4:3]), x: b[2], w: b[1], r: b[0]};
endfunction

// Pack the four cfg bytes of pmpcfg<regn>
function automatic data_t pmpcfg_word(int regn);
    pmpcfg_word = {pmpcfg_of(pmp_table[regn*4+3].cfg), pmpcfg_of(pmp_table[regn*4+2].cfg),
                   pmpcfg_of(pmp_table[regn*4+1].cfg), pmpcfg_of(pmp_table[regn*4+0].cfg)};
endfunction

// Ignore a write to pmpaddr if
//  1) This entry is locked or
//  2) The following entry is TOR and locked
function automatic logic pmpaddr_write_ignored(int i);
    pmpaddr_write_ignored = pmp_table[i].cfg.l ||
                            (i < PMP_ENTRIES-1 &&
                             pmp_table[i+1].cfg.a == PMP_TOR &&
                             pmp_table[i+1].cfg.l);
endfunction

if (ENFORCE_PMP) begin : gen_pmp_table
    logic pmp_csr_wr;
    assign pmp_csr_wr = !trap_in &&
                        !(sret_commit_in || mret_commit_in) &&
                        csr_en_in && instr_ret_in && !wb_csr_ro;

    always_ff @(posedge clk_in or negedge rst_n_in) begin
        if (!rst_n_in) begin
            pmp_table <= '0;
        end else if (pmp_csr_wr) begin
            if (int'(csr_sel_in) >= int'(CSR_PMPCFG0) &&
                int'(csr_sel_in) <  int'(CSR_PMPCFG0) + PMP_ENTRIES/4) begin
                // Writing to pmpcfg
                automatic int base = (int'(csr_sel_in) - int'(CSR_PMPCFG0)) * 4;
                for (int j = 0; j < 4; j++) begin
                    automatic int i = base + j;
                    // Only the first PMP_USABLE entries are functional, the rest are read-only-zero
                    if (i < PMP_USABLE && !pmp_table[i].cfg.l)
                        pmp_table[i].cfg <= cfg_from_byte(csr_data_in[j*8 +: 8]);
                end
            end else if (int'(csr_sel_in) >= int'(CSR_PMPADDR0) &&
                         int'(csr_sel_in) <  int'(CSR_PMPADDR0) + PMP_ENTRIES) begin
                // Writing to pmpaddr
                automatic int i = int'(csr_sel_in) - int'(CSR_PMPADDR0);
                // Ignore write if unusable (read-only-zero entry), or this/following TOR entry is locked
                if (i < PMP_USABLE && !pmpaddr_write_ignored(i)) begin
                    pmp_table[i].addr       <= csr_data_in;
                end
            end
        end
    end
end else begin : gen_no_pmp_table
    assign pmp_table = '0;
end

// ============================================================
// CSR write
// ============================================================

function automatic mode_e legalize_mode(logic[1:0] mode);
    mode_e m = mode_e'(mode);
    legalize_mode = (m == M_MODE || m == S_MODE || m == U_MODE) ? m : U_MODE;
endfunction

always_ff @(posedge clk_in or negedge rst_n_in) begin
    if(!rst_n_in) begin
        csr <= '0;
        csr.dcsr.debugver <= 4;  // Debug specification version 1.0 implemented
        csr.dcsr.prv      <= M_MODE;
    end else begin
        if (trap_csr_en_in) begin
            if (trap_to_debug_in) begin
                csr.dpc        <= trap_epc_in;
                csr.dcsr.prv   <= mode_in;
                csr.dcsr.cause <= dcsr_cause_in;

            end else if (trap_to_s_in) begin
                csr.sepc         <= trap_epc_in;
                csr.mstatus.spie <= csr.mstatus.sie;
                csr.mstatus.sie  <= 1'b0;
                csr.mstatus.spp  <= (trap_mode_in == S_MODE) ? 1'b1 : 1'b0;
                csr.scause       <= trap_cause_in;
                csr.stval        <= trap_tval_in;

            end else begin
                csr.mepc         <= trap_epc_in;
                csr.mstatus.mpie <= csr.mstatus.mie;
                csr.mstatus.mie  <= 1'b0;
                csr.mstatus.mpp  <= legalize_mode(trap_mode_in);
                csr.mcause       <= trap_cause_in;
                csr.mtval        <= trap_tval_in;
            end

        end else if (trap_in || dret_commit_in) begin
            // Trap redirect without CSR capture (taken in debug mode), or DRET commit.
            // Neither writes a CSR, but both drop the retiring CSR write.

        end else if (sret_commit_in) begin
            csr.mstatus.sie  <= csr.mstatus.spie;
            csr.mstatus.spie <= 1'b1;
            csr.mstatus.spp  <= 1'b0;

        end else if (mret_commit_in) begin
            csr.mstatus.mie  <= csr.mstatus.mpie;
            csr.mstatus.mpie <= 1'b1;
            csr.mstatus.mpp  <= U_MODE;
            if (csr.mstatus.mpp != M_MODE)
                csr.mstatus.mprv <= 1'b0;

        end else if (csr_en_in && instr_ret_in && !wb_csr_ro) begin
            case (csr_sel_in)
                // Supervisor Trap Setup (aliased into mstatus/mie)
                CSR_SSTATUS: begin
                    csr.mstatus.sie  <= csr_data_in[1];
                    csr.mstatus.spie <= csr_data_in[5];
                    csr.mstatus.spp  <= csr_data_in[8];
                    csr.mstatus.sum  <= csr_data_in[18];
                    csr.mstatus.mxr  <= csr_data_in[19];
                end
                CSR_SCOUNTEREN: csr.scounteren <= csr_data_in & 32'h0000_0007;
                CSR_SIE: begin  // S-mode visible bits of mie only
                    csr.mie[1] <= csr_data_in[1];
                    csr.mie[5] <= csr_data_in[5];
                    csr.mie[9] <= csr_data_in[9];
                end
                CSR_STVEC:    csr.stvec    <= csr_data_in;
                CSR_SENVCFG:  csr.senvcfg  <= csr_data_in;
                CSR_SSCRATCH: csr.sscratch <= csr_data_in;
                CSR_SEPC:     csr.sepc     <= csr_data_in;
                CSR_SCAUSE:   csr.scause   <= csr_data_in;
                CSR_STVAL:    csr.stval    <= csr_data_in;
                CSR_SIP: begin  // SSIP writable by S-mode; STIP/SEIP only by M-mode
                    csr.ssip <= csr_data_in[1];
                    if (mode_in == M_MODE) begin
                        csr.stip <= csr_data_in[5];
                        csr.seip <= csr_data_in[9];
                    end
                end

                // Supervisor Timer (Sstc)
                CSR_STIMECMP:  csr.stimecmp  <= csr_data_in;
                CSR_STIMECMPH: csr.stimecmph <= csr_data_in;

                // Supervisor Protection and Translation
                CSR_SATP: csr.satp <= csr_data_in;

                // Machine Trap Setup
                CSR_MSTATUS: begin
                    csr.mstatus.sie  <= csr_data_in[1];
                    csr.mstatus.mie  <= csr_data_in[3];
                    csr.mstatus.spie <= csr_data_in[5];
                    csr.mstatus.mpie <= csr_data_in[7];
                    csr.mstatus.spp  <= csr_data_in[8];
                    csr.mstatus.mpp  <= legalize_mode(csr_data_in[12:11]);
                    csr.mstatus.mprv <= csr_data_in[17];
                    csr.mstatus.sum  <= csr_data_in[18];
                    csr.mstatus.mxr  <= csr_data_in[19];
                    csr.mstatus.tvm  <= csr_data_in[20];
                end
                CSR_MEDELEG:    csr.medeleg    <= csr_data_in;
                CSR_MIDELEG:    csr.mideleg    <= csr_data_in & 32'h0000_0222;  // Bits 1,5,9 only
                CSR_MIE:        csr.mie        <= csr_data_in;
                CSR_MTVEC:      csr.mtvec      <= csr_data_in;
                CSR_MCOUNTEREN: csr.mcounteren <= csr_data_in & 32'h0000_0007;
                CSR_MENVCFG:    csr.menvcfg    <= csr_data_in;
                CSR_MENVCFGH:   csr.menvcfgh   <= csr_data_in;
                CSR_MIP: begin  // S-mode soft interrupt bits writable through mip
                    csr.ssip <= csr_data_in[1];
                    csr.stip <= csr_data_in[5];
                    csr.seip <= csr_data_in[9];
                end

                // Machine Trap Handling
                CSR_MSCRATCH: csr.mscratch <= csr_data_in;
                CSR_MEPC:     csr.mepc     <= csr_data_in;
                CSR_MCAUSE:   csr.mcause   <= csr_data_in;

                // Machine Memory Protection: handled below (index-computed)

                // Machine Counter Setup
                CSR_MCOUNTINHIBIT: csr.mcountinhibit <= csr_data_in & 32'h0000_0005;

                // Core Debug Registers
                CSR_DCSR: begin
                    csr.dcsr.ebreakm   <= csr_data_in[15];
                    csr.dcsr.ebreaks   <= csr_data_in[13];
                    csr.dcsr.ebreaku   <= csr_data_in[12];
                    csr.dcsr.stopcount <= csr_data_in[10];
                    csr.dcsr.step      <= csr_data_in[2];
                    csr.dcsr.prv       <= (csr_data_in[1:0] == 2'b10)
                                          ? M_MODE : mode_e'(csr_data_in[1:0]);
                end
                CSR_DPC:       csr.dpc       <= csr_data_in & ~32'h3;
                CSR_DSCRATCH0: csr.dscratch0 <= csr_data_in;
                CSR_DSCRATCH1: csr.dscratch1 <= csr_data_in;

                default: ;
            endcase
        end

        // Update counters if not in debug mode with stopcount set
        if (!(debug_mode_in && csr.dcsr.stopcount)) begin
            // Cycle counter
            if (!csr.mcountinhibit[0]) csr.mcycle <= csr.mcycle + 1;
            // Instruction retire counter
            if (instr_ret_in && !csr.mcountinhibit[2]) csr.minstret <= csr.minstret + 1;
        end
    end
end

// ============================================================
// CSR read
// ============================================================

localparam logic ENABLE_EXTENSION_M = ENABLE_MUL && ENABLE_DIV;

always_comb begin : csr_read
    csr_not_implemented = 1'b0;
    case (selected_csr)
        // Set in block below
        CSR_PMPCFG0:  csr_out = 32'h0;
        CSR_PMPADDR0: csr_out = 32'h0;

        // Machine Information Registers
        CSR_MVENDORID:     csr_out = 32'h0;
        CSR_MARCHID:       csr_out = 32'h0;
        CSR_MIMPID:        csr_out = 32'h0;
        CSR_MHARTID:       csr_out = HART_ID;
        CSR_MCONFIGPTR:    csr_out = 32'h0;

        // Machine Trap Setup
        CSR_MSTATUS:       csr_out = csr.mstatus;
        // M and A bits are generated dynamically based on parameters.
        // When adding new extensions, set the corresponding MISA bits from config, unless always present.
        //                                mx----zyxwvutsrqpon m                        lkjihgfedcb a
        CSR_MISA:          csr_out = {19'b0100000000010100000,{ENABLE_EXTENSION_M},11'b00010000000,{ENABLE_EXTENSION_A}};
        CSR_MEDELEG:       csr_out = csr.medeleg;
        CSR_MIDELEG:       csr_out = csr.mideleg;
        CSR_MIE:           csr_out = csr.mie;
        CSR_MTVEC:         csr_out = csr.mtvec;
        CSR_MCOUNTEREN:    csr_out = csr.mcounteren;
        CSR_MENVCFG:       csr_out = csr.menvcfg;
        CSR_MENVCFGH:      csr_out = csr.menvcfgh;
        CSR_MSTATUSH:      csr_out = 32'h0;

        // Machine Trap Handling
        CSR_MSCRATCH:      csr_out = csr.mscratch;
        CSR_MEPC:          csr_out = csr.mepc;
        CSR_MCAUSE:        csr_out = csr.mcause;
        CSR_MTVAL:         csr_out = csr.mtval;
        CSR_MIP:           csr_out = {20'b0, meip_in, 1'b0, seip_eff, 1'b0, mtip_in, 1'b0, stip_eff, 1'b0, msip_in, 1'b0, csr.ssip, 1'b0};

        // Machine Counter/Timers
        CSR_MCYCLE:        csr_out = csr.mcycle[31:0];
        CSR_MINSTRET:      csr_out = csr.minstret[31:0];
        CSR_MCYCLEH:       csr_out = csr.mcycle[63:32];
        CSR_MINSTRETH:     csr_out = csr.minstret[63:32];

        // Machine Counter Setup
        CSR_MCOUNTINHIBIT: csr_out = csr.mcountinhibit;

        // User/Supervisor Counter/Timer shadows (read-only)
        CSR_CYCLE:         csr_out = csr.mcycle[31:0];
        CSR_INSTRET:       csr_out = csr.minstret[31:0];
        CSR_CYCLEH:        csr_out = csr.mcycle[63:32];
        CSR_INSTRETH:      csr_out = csr.minstret[63:32];
        CSR_TIME:          csr_out = mtime_in[31:0];
        CSR_TIMEH:         csr_out = mtime_in[63:32];

        // Supervisor Trap Setup
        // sstatus is mstatus with M-mode-only bits (MIE[3], MPIE[7], MPP[12:11], MPRV[17]) zeroed
        CSR_SSTATUS:       csr_out = data_t'(csr.mstatus) & ~32'h0002_1888;
        CSR_SCOUNTEREN:    csr_out = csr.scounteren;
        CSR_SIE:           csr_out = csr.mie & 32'h0000_0222;  // S-mode bits: SEIE[9], STIE[5], SSIE[1]
        CSR_STVEC:         csr_out = csr.stvec;
        CSR_SENVCFG:       csr_out = csr.senvcfg;
        CSR_SSCRATCH:      csr_out = csr.sscratch;
        CSR_SEPC:          csr_out = csr.sepc;
        CSR_SCAUSE:        csr_out = csr.scause;
        CSR_STVAL:         csr_out = csr.stval;
        // S-mode visible interrupt pending bits only
        CSR_SIP:           csr_out = {22'b0, seip_eff, 3'b0, stip_eff, 3'b0, csr.ssip, 1'b0};

        // Supervisor Timer (Sstc)
        CSR_STIMECMP:      csr_out = csr.stimecmp;
        CSR_STIMECMPH:     csr_out = csr.stimecmph;

        // Supervisor Protection and Translation
        CSR_SATP:          csr_out = csr.satp;

        // Core Debug Registers
        CSR_DCSR:      begin csr_out = csr.dcsr;      csr_not_implemented = !debug_mode_in; end
        CSR_DPC:       begin csr_out = csr.dpc;       csr_not_implemented = !debug_mode_in; end
        CSR_DSCRATCH0: begin csr_out = csr.dscratch0; csr_not_implemented = !debug_mode_in; end
        CSR_DSCRATCH1: begin csr_out = csr.dscratch1; csr_not_implemented = !debug_mode_in; end

        default: begin
            csr_out             = 32'h0;
            csr_not_implemented = 1'b1;
        end
    endcase

    // Machine Memory Protection
    if (int'(selected_csr) >= int'(CSR_PMPCFG0) &&
        int'(selected_csr) <  int'(CSR_PMPCFG0) + PMP_ENTRIES/4) begin
        csr_out = ENFORCE_PMP ? pmpcfg_word(int'(selected_csr) - int'(CSR_PMPCFG0)) : 32'h0;
        csr_not_implemented = 1'b0;
    end else if (int'(selected_csr) >= int'(CSR_PMPADDR0) &&
                 int'(selected_csr) <  int'(CSR_PMPADDR0) + PMP_ENTRIES) begin
        csr_out = ENFORCE_PMP ? pmp_table[int'(selected_csr) - int'(CSR_PMPADDR0)].addr : 32'h0;
        csr_not_implemented = 1'b0;
    end
end

// ============================================================
// MMU outputs
// ============================================================

assign satp_out = csr.satp;
assign sum_out  = csr.mstatus.sum;
assign mxr_out  = csr.mstatus.mxr;
assign data_mode_out = (!debug_mode_in && mode_in == M_MODE && csr.mstatus.mprv)
                       ? csr.mstatus.mpp : mode_in;

endmodule

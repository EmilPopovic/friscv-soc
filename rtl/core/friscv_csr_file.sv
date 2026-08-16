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

module friscv_csr_file
    import friscv_pkg::*;
#(
    parameter int unsigned HartId = 0,

    parameter bit          EnforcePmp = 0,
    parameter int unsigned PmpEntries = 8,
    parameter int unsigned PmpUsable  = 8,

    parameter bit EnableIsaE = 0,
    parameter bit EnableIsaM = 1,
    parameter bit EnableIsaA = 1
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // Hart state from the trap controller
    input  mode_e       mode_i,
    input  logic        debug_mode_i,

    // CSR read
    input  csr_addr_e   selected_csr_i,
    output data_t       csr_o,
    output logic        csr_not_impl_o,

    // CSR write from WB
    input  csr_addr_e   csr_sel_i,
    input  logic        csr_en_i,
    input  data_t       csr_data_i,
    input  logic        instr_ret_i,

    // Trap commit commands from the trap controller
    input  logic        trap_i,           // Trap redirect this cycle, inhibits the retiring CSR write
    input  logic        trap_csr_en_i,    // Capture trap state into CSRs this cycle
    input  logic        trap_to_debug_i,  // Debug entry, write dpc/dcsr instead of xepc/xcause
    input  logic        trap_to_s_i,      // Delegated, write sepc/scause/stval instead of M equivalents
    input  addr_t       trap_epc_i,
    input  data_t       trap_cause_i,
    input  data_t       trap_tval_i,
    input  mode_e       trap_mode_i,      // Privilege mode the trap originated from (for mpp/spp)
    input  logic [2:0]  dcsr_cause_i,     // Debug entry cause for dcsr.cause
    input  logic        mret_commit_i,
    input  logic        sret_commit_i,
    input  logic        dret_commit_i,

    // CSR state to the trap controller
    output mstatus_t    mstatus_o,
    output addr_t       mtvec_o,
    output addr_t       stvec_o,
    output data_t       medeleg_o,
    output data_t       mideleg_o,
    output data_t       mie_o,
    output dcsr_t       dcsr_o,
    output addr_t       dpc_o,
    output addr_t       sepc_o,
    output addr_t       mepc_o,
    output logic        ssip_o,
    output logic        stip_eff_o,
    output logic        seip_eff_o,

    // Interrupt pending inputs
    input  logic        msip_i,
    input  logic        mtip_i,
    input  logic        meip_i,
    input  logic        seip_i,

    // Counter/Timer
    input  mtime_t      mtime_i,
    output data_t       mcounteren_o,
    output data_t       scounteren_o,

    // Memory protection
    output pmp_entry_t [PmpEntries-1:0] pmp_table_o,

    // To MMU
    output satp_t       satp_o,
    output logic        sum_o,
    output logic        mxr_o,
    output mode_e       data_mode_o
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

assign mstatus_o    = csr.mstatus;
assign mtvec_o      = csr.mtvec;
assign stvec_o      = csr.stvec;
assign mcounteren_o = csr.mcounteren;
assign scounteren_o = csr.scounteren;
assign medeleg_o    = csr.medeleg;
assign mideleg_o    = csr.mideleg;
assign mie_o        = csr.mie;
assign dpc_o        = csr.dpc;
assign sepc_o       = csr.sepc;
assign mepc_o       = csr.mepc;
assign dcsr_o       = csr.dcsr;

assign ssip_o = csr.ssip;

// Registered output of 64-bit compare
logic stimecmp_result;
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) stimecmp_result <= 1'b0;
    else           stimecmp_result <= (mtime_i >= {csr.stimecmph, csr.stimecmp});
end

// STIP has two sources:
//  1) Hardware: when mtime >= stimecmp, and menvcfgh[31] enables this behavior
//  2) Software: when M-mode or S-mode writes to the STIP bit in mip
// stip_eff is the effective STIP value taking both into account. SEIP likewise
// combines the mip bit with the external pin.
logic stip_eff, seip_eff;
assign stip_eff = csr.stip || (csr.menvcfgh[31] && stimecmp_result);
assign seip_eff = csr.seip || seip_i;

assign stip_eff_o = stip_eff;
assign seip_eff_o = seip_eff;

// Read-only status of CSR being written back
// This is to protect the state of read-only CSRs, but should never be true
// as writes to read-only CSRs will be decoded as illegal instructions and trap.
logic wb_csr_ro;
assign wb_csr_ro = csr_sel_i[11:10] == 2'b11;

////////////////////////////////
// Physical Memory Protection //
////////////////////////////////

pmp_entry_t [PmpEntries-1:0] pmp_table;
assign pmp_table_o = pmp_table;

// Pack a pmp_cfg_t struct into its 8-bit pmpcfg byte
function automatic logic [7:0] pmpcfg_of(pmp_cfg_t pmp_cfg);
    return {pmp_cfg.l, 2'b00, pmp_cfg.a, pmp_cfg.x, pmp_cfg.w, pmp_cfg.r};
endfunction

// Decode an 8-bit pmpcfg byte into a pmp_cfg_t struct
function automatic pmp_cfg_t cfg_from_byte(logic [7:0] b);
    if (b[1] && !b[0]) return '{l: b[7], a: pmp_mode_e'(b[4:3]), x: 1'b0, w: 1'b0, r: 1'b0};
    else               return '{l: b[7], a: pmp_mode_e'(b[4:3]), x: b[2], w: b[1], r: b[0]};
endfunction

// Pack the four cfg bytes of pmpcfg<regn>
function automatic data_t pmpcfg_word(logic [11:0] regn);
   return {pmpcfg_of(pmp_table[regn*4+3].cfg), pmpcfg_of(pmp_table[regn*4+2].cfg),
           pmpcfg_of(pmp_table[regn*4+1].cfg), pmpcfg_of(pmp_table[regn*4+0].cfg)};
endfunction

// Ignore a write to pmpaddr if
//  1) This entry is locked or
//  2) The following entry is TOR and locked
function automatic logic pmpaddr_write_ignored(logic [11:0] i);
    return pmp_table[i].cfg.l ||
           (i < 12'(PmpEntries-1) &&
            pmp_table[i+1].cfg.a == PMP_TOR &&
            pmp_table[i+1].cfg.l);
endfunction

if (EnforcePmp) begin : gen_pmp_table
    logic pmp_csr_wr;
    assign pmp_csr_wr = !trap_i &&
                        !(sret_commit_i || mret_commit_i) &&
                        csr_en_i && instr_ret_i && !wb_csr_ro;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pmp_table <= '0;
        end else if (pmp_csr_wr) begin
            if (int'(csr_sel_i) >= int'(CSR_PMPCFG0) &&
                int'(csr_sel_i) <  int'(CSR_PMPCFG0) + PmpEntries/4) begin
                // Writing to pmpcfg
                automatic int base = (int'(csr_sel_i) - int'(CSR_PMPCFG0)) * 4;
                for (int j = 0; j < 4; j++) begin
                    automatic int i = base + j;
                    // Only the first PMP_USABLE entries are functional,
                    // the rest are read-only-zero
                    if (i < PmpUsable && !pmp_table[i].cfg.l)
                        pmp_table[i].cfg <= cfg_from_byte(csr_data_i[j*8 +: 8]);
                end
            end else if (int'(csr_sel_i) >= int'(CSR_PMPADDR0) &&
                         int'(csr_sel_i) <  int'(CSR_PMPADDR0) + PmpEntries) begin
                // Writing to pmpaddr
                automatic int i = int'(csr_sel_i) - int'(CSR_PMPADDR0);
                // Ignore write if unusable (read-only-zero entry)
                // or this/following TOR entry is locked
                if (i < PmpUsable && !pmpaddr_write_ignored(i)) begin
                    pmp_table[i].addr <= csr_data_i;
                end
            end
        end
    end
end else begin : gen_no_pmp_table
    assign pmp_table = '0;
end

///////////////
// CSR write //
///////////////

function automatic mode_e legalize_mode(logic[1:0] mode);
    mode_e m = mode_e'(mode);
    return (m == M_MODE || m == S_MODE || m == U_MODE) ? m : U_MODE;
endfunction

always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
        csr <= '0;
        csr.dcsr.debugver <= 4'd4;  // Debug specification version 1.0 implemented
        csr.dcsr.prv      <= M_MODE;
    end else begin
        if (trap_csr_en_i) begin
            if (trap_to_debug_i) begin
                csr.dpc        <= trap_epc_i;
                csr.dcsr.prv   <= mode_i;
                csr.dcsr.cause <= dcsr_cause_i;

            end else if (trap_to_s_i) begin
                csr.sepc         <= trap_epc_i;
                csr.mstatus.spie <= csr.mstatus.sie;
                csr.mstatus.sie  <= 1'b0;
                csr.mstatus.spp  <= (trap_mode_i == S_MODE) ? 1'b1 : 1'b0;
                csr.scause       <= trap_cause_i;
                csr.stval        <= trap_tval_i;
            end else begin
                csr.mepc         <= trap_epc_i;
                csr.mstatus.mpie <= csr.mstatus.mie;
                csr.mstatus.mie  <= 1'b0;
                csr.mstatus.mpp  <= legalize_mode(trap_mode_i);
                csr.mcause       <= trap_cause_i;
                csr.mtval        <= trap_tval_i;
            end

        end else if (trap_i || dret_commit_i) begin
            // Trap redirect without CSR capture (taken in debug mode), or DRET commit.
            // Neither writes a CSR, but both drop the retiring CSR write.

        end else if (sret_commit_i) begin
            csr.mstatus.sie  <= csr.mstatus.spie;
            csr.mstatus.spie <= 1'b1;
            csr.mstatus.spp  <= 1'b0;

        end else if (mret_commit_i) begin
            csr.mstatus.mie  <= csr.mstatus.mpie;
            csr.mstatus.mpie <= 1'b1;
            csr.mstatus.mpp  <= U_MODE;
            if (csr.mstatus.mpp != M_MODE)
                csr.mstatus.mprv <= 1'b0;

        end else if (csr_en_i && instr_ret_i && !wb_csr_ro) begin
            `pragma diagnostic push
            `pragma diagnostic ignore="-Wcase-enum-explicit"
            unique case (csr_sel_i)
                // Supervisor Trap Setup (aliased into mstatus/mie)
                CSR_SSTATUS: begin
                    csr.mstatus.sie  <= csr_data_i[1];
                    csr.mstatus.spie <= csr_data_i[5];
                    csr.mstatus.spp  <= csr_data_i[8];
                    csr.mstatus.sum  <= csr_data_i[18];
                    csr.mstatus.mxr  <= csr_data_i[19];
                end
                CSR_SCOUNTEREN: csr.scounteren <= csr_data_i & 32'h0000_0007;
                CSR_SIE: begin  // S-mode visible bits of mie only
                    csr.mie[1] <= csr_data_i[1];
                    csr.mie[5] <= csr_data_i[5];
                    csr.mie[9] <= csr_data_i[9];
                end
                CSR_STVEC:    csr.stvec    <= csr_data_i;
                CSR_SENVCFG:  csr.senvcfg  <= csr_data_i;
                CSR_SSCRATCH: csr.sscratch <= csr_data_i;
                CSR_SEPC:     csr.sepc     <= csr_data_i;
                CSR_SCAUSE:   csr.scause   <= csr_data_i;
                CSR_STVAL:    csr.stval    <= csr_data_i;
                CSR_SIP: begin  // SSIP writable by S-mode; STIP/SEIP only by M-mode
                    csr.ssip <= csr_data_i[1];
                    if (mode_i == M_MODE) begin
                        csr.stip <= csr_data_i[5];
                        csr.seip <= csr_data_i[9];
                    end
                end

                // Supervisor Timer (Sstc)
                CSR_STIMECMP:  csr.stimecmp  <= csr_data_i;
                CSR_STIMECMPH: csr.stimecmph <= csr_data_i;

                // Supervisor Protection and Translation
                CSR_SATP: csr.satp <= csr_data_i;

                // Machine Trap Setup
                CSR_MSTATUS: begin
                    csr.mstatus.sie  <= csr_data_i[1];
                    csr.mstatus.mie  <= csr_data_i[3];
                    csr.mstatus.spie <= csr_data_i[5];
                    csr.mstatus.mpie <= csr_data_i[7];
                    csr.mstatus.spp  <= csr_data_i[8];
                    csr.mstatus.mpp  <= legalize_mode(csr_data_i[12:11]);
                    csr.mstatus.mprv <= csr_data_i[17];
                    csr.mstatus.sum  <= csr_data_i[18];
                    csr.mstatus.mxr  <= csr_data_i[19];
                    csr.mstatus.tvm  <= csr_data_i[20];
                end
                CSR_MEDELEG:    csr.medeleg    <= csr_data_i;
                // Bits 1,5,9 only
                CSR_MIDELEG:    csr.mideleg    <= csr_data_i & 32'h0000_0222;
                CSR_MIE:        csr.mie        <= csr_data_i;
                CSR_MTVEC:      csr.mtvec      <= csr_data_i;
                CSR_MCOUNTEREN: csr.mcounteren <= csr_data_i & 32'h0000_0007;
                CSR_MENVCFG:    csr.menvcfg    <= csr_data_i;
                CSR_MENVCFGH:   csr.menvcfgh   <= csr_data_i;
                CSR_MIP: begin  // S-mode soft interrupt bits writable through mip
                    csr.ssip <= csr_data_i[1];
                    csr.stip <= csr_data_i[5];
                    csr.seip <= csr_data_i[9];
                end

                // Machine Trap Handling
                CSR_MSCRATCH: csr.mscratch <= csr_data_i;
                CSR_MEPC:     csr.mepc     <= csr_data_i;
                CSR_MCAUSE:   csr.mcause   <= csr_data_i;

                // Machine Memory Protection: handled below (index-computed)

                // Machine Counter Setup
                CSR_MCOUNTINHIBIT: csr.mcountinhibit <= csr_data_i & 32'h0000_0005;

                // Core Debug Registers
                CSR_DCSR: begin
                    csr.dcsr.ebreakm   <= csr_data_i[15];
                    csr.dcsr.ebreaks   <= csr_data_i[13];
                    csr.dcsr.ebreaku   <= csr_data_i[12];
                    csr.dcsr.stopcount <= csr_data_i[10];
                    csr.dcsr.step      <= csr_data_i[2];
                    csr.dcsr.prv       <= (csr_data_i[1:0] == 2'b10)
                                          ? M_MODE : mode_e'(csr_data_i[1:0]);
                end
                CSR_DPC:       csr.dpc       <= csr_data_i & ~32'h3;
                CSR_DSCRATCH0: csr.dscratch0 <= csr_data_i;
                CSR_DSCRATCH1: csr.dscratch1 <= csr_data_i;

                default: ;
            endcase
            `pragma diagnostic pop
        end

        // Update counters if not in debug mode with stopcount set
        if (!(debug_mode_i && csr.dcsr.stopcount)) begin
            // Cycle counter
            if (!csr.mcountinhibit[0]) csr.mcycle <= csr.mcycle + 1;
            // Instruction retire counter
            if (instr_ret_i && !csr.mcountinhibit[2]) csr.minstret <= csr.minstret + 1;
        end
    end
end

//////////////
// CSR read //
//////////////

always_comb begin : csr_read
    csr_not_impl_o = 1'b0;
    `pragma diagnostic push
    `pragma diagnostic ignore="-Wcase-enum-explicit"
    unique case (selected_csr_i)
        // Set in block below
        CSR_PMPCFG0:  csr_o = 32'h0;
        CSR_PMPADDR0: csr_o = 32'h0;

        // Machine Information Registers
        CSR_MVENDORID:     csr_o = 32'h0;
        CSR_MARCHID:       csr_o = 32'h0;
        CSR_MIMPID:        csr_o = 32'h0;
        CSR_MHARTID:       csr_o = HartId;
        CSR_MCONFIGPTR:    csr_o = 32'h0;

        // Machine Trap Setup
        CSR_MSTATUS:       csr_o = csr.mstatus;
        // TODO this line is very long
        // When adding new extensions, set MISA bits from config, unless always present.
        //                              mx----zyxwvutsrqpon m               lkj i                hgf e               dcb a
        CSR_MISA:          csr_o = {19'b0100000000010100000,{EnableIsaM},3'b000,{!EnableIsaE},3'b000,{EnableIsaE},3'b000,{EnableIsaA}};
        CSR_MEDELEG:       csr_o = csr.medeleg;
        CSR_MIDELEG:       csr_o = csr.mideleg;
        CSR_MIE:           csr_o = csr.mie;
        CSR_MTVEC:         csr_o = csr.mtvec;
        CSR_MCOUNTEREN:    csr_o = csr.mcounteren;
        CSR_MENVCFG:       csr_o = csr.menvcfg;
        CSR_MENVCFGH:      csr_o = csr.menvcfgh;
        CSR_MSTATUSH:      csr_o = 32'h0;

        // Machine Trap Handling
        CSR_MSCRATCH:      csr_o = csr.mscratch;
        CSR_MEPC:          csr_o = csr.mepc;
        CSR_MCAUSE:        csr_o = csr.mcause;
        CSR_MTVAL:         csr_o = csr.mtval;
        CSR_MIP:           csr_o = {20'b0, meip_i, 1'b0, seip_eff, 1'b0, mtip_i, 1'b0,
                                    stip_eff, 1'b0, msip_i, 1'b0, csr.ssip, 1'b0};

        // Machine Counter/Timers
        CSR_MCYCLE:        csr_o = csr.mcycle[31:0];
        CSR_MINSTRET:      csr_o = csr.minstret[31:0];
        CSR_MCYCLEH:       csr_o = csr.mcycle[63:32];
        CSR_MINSTRETH:     csr_o = csr.minstret[63:32];

        // Machine Counter Setup
        CSR_MCOUNTINHIBIT: csr_o = csr.mcountinhibit;

        // User/Supervisor Counter/Timer shadows (read-only)
        CSR_CYCLE:         csr_o = csr.mcycle[31:0];
        CSR_INSTRET:       csr_o = csr.minstret[31:0];
        CSR_CYCLEH:        csr_o = csr.mcycle[63:32];
        CSR_INSTRETH:      csr_o = csr.minstret[63:32];
        CSR_TIME:          csr_o = mtime_i[31:0];
        CSR_TIMEH:         csr_o = mtime_i[63:32];

        // Supervisor Trap Setup
        // sstatus is mstatus with M-mode-only bits (MIE[3], MPIE[7], MPP[12:11], MPRV[17]) zeroed
        CSR_SSTATUS:       csr_o = data_t'(csr.mstatus) & ~32'h0002_1888;
        CSR_SCOUNTEREN:    csr_o = csr.scounteren;
        // S-mode bits: SEIE[9], STIE[5], SSIE[1]
        CSR_SIE:           csr_o = csr.mie & 32'h0000_0222;
        CSR_STVEC:         csr_o = csr.stvec;
        CSR_SENVCFG:       csr_o = csr.senvcfg;
        CSR_SSCRATCH:      csr_o = csr.sscratch;
        CSR_SEPC:          csr_o = csr.sepc;
        CSR_SCAUSE:        csr_o = csr.scause;
        CSR_STVAL:         csr_o = csr.stval;
        // S-mode visible interrupt pending bits only
        CSR_SIP:           csr_o = {22'b0, seip_eff, 3'b0, stip_eff, 3'b0, csr.ssip, 1'b0};

        // Supervisor Timer (Sstc)
        CSR_STIMECMP:      csr_o = csr.stimecmp;
        CSR_STIMECMPH:     csr_o = csr.stimecmph;

        // Supervisor Protection and Translation
        CSR_SATP:          csr_o = csr.satp;

        // Core Debug Registers
        CSR_DCSR:      begin csr_o = csr.dcsr;      csr_not_impl_o = !debug_mode_i; end
        CSR_DPC:       begin csr_o = csr.dpc;       csr_not_impl_o = !debug_mode_i; end
        CSR_DSCRATCH0: begin csr_o = csr.dscratch0; csr_not_impl_o = !debug_mode_i; end
        CSR_DSCRATCH1: begin csr_o = csr.dscratch1; csr_not_impl_o = !debug_mode_i; end

        default: begin
            csr_o = 32'h0;
            csr_not_impl_o = 1'b1;
        end
    endcase
    `pragma diagnostic pop

    // Machine Memory Protection
    if (int'(selected_csr_i) >= int'(CSR_PMPCFG0) &&
        int'(selected_csr_i) <  int'(CSR_PMPCFG0) + int'(PmpEntries/4)) begin
        csr_o = EnforcePmp ? pmpcfg_word(selected_csr_i - csr_addr_e'(CSR_PMPCFG0)) : 32'h0;
        csr_not_impl_o = 1'b0;
    end else if (int'(selected_csr_i) >= int'(CSR_PMPADDR0) &&
                 int'(selected_csr_i) <  int'(CSR_PMPADDR0) + int'(PmpEntries)) begin
        csr_o = EnforcePmp ? pmp_table[selected_csr_i - csr_addr_e'(CSR_PMPADDR0)].addr : 32'h0;
        csr_not_impl_o = 1'b0;
    end
end

/////////////////
// MMU outputs //
/////////////////

assign satp_o = csr.satp;
assign sum_o  = csr.mstatus.sum;
assign mxr_o  = csr.mstatus.mxr;
assign data_mode_o = (!debug_mode_i && mode_i == M_MODE && csr.mstatus.mprv)
                   ? csr.mstatus.mpp : mode_i;

endmodule

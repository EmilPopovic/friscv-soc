// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the Memory Management Unit (MMU) of the FRISC-V CPU subsystem.
 * It handles virtual to physical address translation, TLB management, page fault generation,
 * and memory interface arbitration.
 */

module friscv_mmu
    import friscv_pkg::*;
#(
    parameter bit          EnforcePmp    = 0,
    parameter bit          EnforcePtwPmp = 0,
    parameter int unsigned PmpEntries    = 8,
    // Must be a power of 2 greater than 1
    parameter int unsigned ItlbEntries = 2,
    parameter int unsigned DtlbEntries = 4,
    // If not enabled, any sfence.vma will flush all TLB entries
    parameter bit          EnableFineTlbFlush = 0
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // Instruction Memory Interface
    input  addr_t       inst_addr_i,
    output data_t       inst_data_o,
    input  logic        inst_en_i,
    output logic        inst_wait_o,
    output logic        inst_err_o,
    output logic        inst_pmp_fault_o,

    // Data Memory Interface
    input  addr_t       data_addr_i,
    input  mem_width_e  data_size_i,
    input  data_t       data_wdata_i,
    output data_t       data_rdata_o,
    input  logic        data_en_i,
    input  logic        data_wr_i,
    input  logic        data_store_like_i,
    output logic        data_wait_o,
    output logic        data_err_o,
    output logic        data_pmp_fault_o,
    input  amo_op_e     amo_op_i,

    // External Memory Interface
    output addr_t       mem_addr_o,
    output mem_width_e  mem_size_o,
    output data_t       mem_wdata_o,
    input  data_t       mem_rdata_i,
    output rw_cmd_e     mem_rw_o,
    input  logic        mem_wait_i,
    input  logic        mem_err_i,
    output amo_op_e     amo_op_o,

    // Protection and Translation Control
    input  satp_t       satp_i,
    input  logic        sum_i,
    input  logic        mxr_i,
    input  mode_e       inst_mode_i,
    input  mode_e       data_mode_i,
    input  logic        flush_tlb_i,
    input  vpn_t        flush_vpn_i,
    input  logic        flush_vpn_en_i,
    input  asid_t       flush_asid_i,
    input  logic        flush_asid_en_i,
    input  pmp_entry_t [PmpEntries-1:0] pmp_table_i,

    // Page fault signals
    output logic        inst_fault_o,
    output logic        load_fault_o,
    output logic        store_fault_o,
    output addr_t       fault_addr_o
);

// Granted request lines and latched translation context
mem_width_e   grant_size;
data_t        grant_wdata;
rw_cmd_e      grant_rw;
logic         stall;
amo_op_e      grant_amo;
logic         grant_start;
logic         grant_start_inst;
logic         grant_held;
logic         grant_active;
logic         l1_inst_err;
logic         l1_data_err;
mmu_req_ctx_t r_req_ctx;
mmu_req_ctx_t eff_req_ctx;
mmu_req_ctx_t start_req_ctx;
asid_t        eff_asid;

logic paging_en;

///////////////
// TLB Layer //
///////////////

vpn_t inst_vpn, data_vpn;
assign inst_vpn = (grant_active && eff_req_ctx.is_inst)
                ? vpn_t'(eff_req_ctx.addr[31:12]) : vpn_t'(inst_addr_i[31:12]);
assign data_vpn = (grant_active && !eff_req_ctx.is_inst)
                ? vpn_t'(eff_req_ctx.addr[31:12]) : vpn_t'(data_addr_i[31:12]);

// Lookup lines
ppn_t  itlb_ppn,  dtlb_ppn;
perm_t itlb_perm, dtlb_perm;
logic  itlb_hit,  dtlb_hit;

satp_mode_e tlb_mode;
assign tlb_mode = satp_mode_e'(eff_req_ctx.satp.mode);

// Fill lines
vpn_t       fill_vpn;
ppn_t       fill_ppn;
asid_t      fill_asid;
perm_t      fill_perm;
pte_level_t fill_level;
logic       fill_itlb, fill_dtlb;

// Physical addresses
addr_t inst_pa, data_pa;
assign inst_pa = paging_en ? {itlb_ppn[PA_PPN_W-1:0], inst_addr_i[11:0]} : inst_addr_i;
assign data_pa = paging_en ? {dtlb_ppn[PA_PPN_W-1:0], data_addr_i[11:0]} : data_addr_i;

friscv_tlb #(
    .EntryCount         ( ItlbEntries        ),
    .EnableFineTlbFlush ( EnableFineTlbFlush )
) i_itlb (
    .clk_i,
    .rst_ni,

    // Lookup
    .match_vpn_i     ( inst_vpn        ),
    .mode_i          ( tlb_mode        ),
    .match_asid_i    ( eff_asid        ),
    .ppn_o           ( itlb_ppn        ),
    .perm_o          ( itlb_perm       ),
    .hit_o           ( itlb_hit        ),

    // Fill
    .fill_vpn_i      ( fill_vpn        ),
    .fill_ppn_i      ( fill_ppn        ),
    .fill_asid_i     ( fill_asid       ),
    .fill_perm_i     ( fill_perm       ),
    .fill_level_i    ( fill_level      ),
    .fill_en_i       ( fill_itlb       ),

    // Flush
    .flush_i         ( flush_tlb_i     ),
    .flush_vpn_i     ( flush_vpn_i     ),
    .flush_vpn_en_i  ( flush_vpn_en_i  ),
    .flush_asid_i    ( flush_asid_i    ),
    .flush_asid_en_i ( flush_asid_en_i )
);

friscv_tlb #(
    .EntryCount         ( DtlbEntries        ),
    .EnableFineTlbFlush ( EnableFineTlbFlush )
) i_dtlb (
    .clk_i,
    .rst_ni,

    // Lookup
    .match_vpn_i     ( data_vpn        ),
    .mode_i          ( tlb_mode        ),
    .match_asid_i    ( eff_asid        ),
    .ppn_o           ( dtlb_ppn        ),
    .perm_o          ( dtlb_perm       ),
    .hit_o           ( dtlb_hit        ),

    // Fill
    .fill_vpn_i      ( fill_vpn        ),
    .fill_ppn_i      ( fill_ppn        ),
    .fill_asid_i     ( fill_asid       ),
    .fill_perm_i     ( fill_perm       ),
    .fill_level_i    ( fill_level      ),
    .fill_en_i       ( fill_dtlb       ),

    // Flush
    .flush_i         ( flush_tlb_i     ),
    .flush_vpn_i     ( flush_vpn_i     ),
    .flush_vpn_en_i  ( flush_vpn_en_i  ),
    .flush_asid_i    ( flush_asid_i    ),
    .flush_asid_en_i ( flush_asid_en_i )
);

///////////////////////
// Arbitration Layer //
///////////////////////

`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
friscv_arbiter i_arbiter (
    .clk_i,
    .rst_ni,

    .inst_addr_i,
    .inst_data_o,
    .inst_en_i,
    .inst_wait_o,
    .inst_err_o         ( l1_inst_err      ),

    .data_addr_i,
    .data_size_i,
    .data_wdata_i,
    .data_rdata_o,
    .data_en_i,
    .data_wr_i,
    .data_wait_o,
    .amo_op_i,
    .data_err_o         ( l1_data_err      ),

    .mem_addr_o         (                  ),
    .mem_size_o         ( grant_size       ),
    .mem_wdata_o        ( grant_wdata      ),
    .mem_rdata_i,
    .mem_rw_o           ( grant_rw         ),
    .mem_wait_i         ( stall            ),
    .mem_err_i,
    .amo_op_o           ( grant_amo        ),
    .grant_start_o      ( grant_start      ),
    .grant_start_inst_o ( grant_start_inst ),
    .grant_held_o       ( grant_held       )
);
`pragma diagnostic pop

//////////////////
// Paging Layer //
//////////////////

// Paging active when satp.MODE != 0 and not in M-mode
assign paging_en = (|eff_req_ctx.satp.mode) && (eff_req_ctx.mode != M_MODE);

// Arbiter is in a grant state when it drives a non-idle command
assign grant_active = (grant_rw != RW_IDLE);

always_comb begin
    start_req_ctx.addr     = grant_start_inst ? inst_addr_i : data_addr_i;
    start_req_ctx.satp     = satp_i;
    start_req_ctx.mode     = grant_start_inst ? inst_mode_i : data_mode_i;
    start_req_ctx.sum      = sum_i;
    start_req_ctx.mxr      = mxr_i;
    start_req_ctx.is_inst  = grant_start_inst;
    start_req_ctx.is_write = !grant_start_inst &&
                             (data_wr_i || data_store_like_i || (amo_op_i != AMO_NONE));
end

always_comb begin
    eff_req_ctx = grant_held ? r_req_ctx : start_req_ctx;
    eff_asid    = eff_req_ctx.satp.asid;
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)            r_req_ctx <= '0;
    else if (grant_start) r_req_ctx <= start_req_ctx;
end

// TLB validity gate
vpn_t r_ivpn_q, r_dvpn_q;
// A fill/flush last cycle, the registered TLB result is stale this cycle
logic r_tlb_changed;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        r_ivpn_q      <= '0;
        r_dvpn_q      <= '0;
        r_tlb_changed <= 1'b0;
    end else begin
        r_ivpn_q      <= inst_vpn;
        r_dvpn_q      <= data_vpn;
        r_tlb_changed <= fill_itlb | fill_dtlb | flush_tlb_i;
    end
end

// A request the memory has taken cannot be withdrawn, so it must not be
// translated again. An sfence.vma in between would make it a TLB miss and
// the walk would read the request's own response as its PTE.
logic  r_access_busy;
addr_t r_access_pa, tlate_pa;
logic  walk_en;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        r_access_busy <= 1'b0;
        r_access_pa   <= '0;
    end else if (!mem_wait_i) begin
        r_access_busy <= 1'b0;
    end else if (!r_access_busy && !walk_en && mem_rw_o != RW_IDLE) begin
        r_access_busy <= 1'b1;
        r_access_pa   <= tlate_pa;
    end
end

// The registered TLB output is valid for this access only when
//  1) its VPN was the one looked up last cycle and
//  2) no fill/flush last cycle changed the TLB contents
// Pending only matters under paging, a granted access whose registered translation is
// not yet valid for its own VPN must wait
logic tlate_valid, tlate_pending;
assign tlate_valid = !r_tlb_changed &&
                     (eff_req_ctx.is_inst ? (r_ivpn_q == inst_vpn)
                                            : (r_dvpn_q == data_vpn));
assign tlate_pending = paging_en && grant_active && !tlate_valid && !r_access_busy;

// TLB miss - arbiter has granted the request, paging is on, and the TLB did not hit
logic itlb_miss, dtlb_miss, tlb_miss;
assign itlb_miss = grant_active &&
                   eff_req_ctx.is_inst &&
                   !itlb_hit &&
                   paging_en &&
                   !tlate_pending &&
                   !r_access_busy;
assign dtlb_miss = grant_active &&
                   !eff_req_ctx.is_inst &&
                   !dtlb_hit &&
                   paging_en &&
                   !tlate_pending &&
                   !r_access_busy;
assign tlb_miss  = itlb_miss || dtlb_miss;

// PTW memory interface
addr_t walk_addr;
data_t walk_rdata;
logic  walk_wait;
logic  walk_err;
logic  ptw_stall;

// PTW intermediate fault wires
logic  ptw_inst_fault, ptw_load_fault, ptw_store_fault;
addr_t ptw_fault_addr;

// PTW PMP
logic walk_req;
logic ptw_pmp_fault, ptw_access_fault;

friscv_ptw i_ptw (
    .clk_i,
    .rst_ni,

    // Translation control
    .satp_i          ( eff_req_ctx.satp     ),

    // Walk trigger
    .itlb_miss_i     ( itlb_miss            ),
    .dtlb_miss_i     ( dtlb_miss            ),
    .req_va_i        ( eff_req_ctx.addr     ),
    .req_is_write_i  ( eff_req_ctx.is_write ),

    // PMP control
    .pmp_fault_i     ( ptw_pmp_fault        ),
    .walk_req_o      ( walk_req             ),
    .pmp_fault_o     ( ptw_access_fault     ),

    // External bus
    .walk_addr_o     ( walk_addr            ),
    .walk_en_o       ( walk_en              ),
    .walk_rdata_i    ( walk_rdata           ),
    .walk_wait_i     ( walk_wait            ),
    .walk_err_i      ( walk_err             ),

    // Arbiter stall
    .stall_o         ( ptw_stall            ),

    // TLB fill
    .fill_vpn_o      ( fill_vpn             ),
    .fill_ppn_o      ( fill_ppn             ),
    .fill_asid_o     ( fill_asid            ),
    .fill_perm_o     ( fill_perm            ),
    .fill_level_o    ( fill_level           ),
    .fill_itlb_en_o  ( fill_itlb            ),
    .fill_dtlb_en_o  ( fill_dtlb            ),

    // Page fault outputs
    .inst_fault_o    ( ptw_inst_fault       ),
    .load_fault_o    ( ptw_load_fault       ),
    .store_fault_o   ( ptw_store_fault      ),
    .fault_addr_o    ( ptw_fault_addr       )
);

if (EnforcePmp && EnforcePtwPmp) begin : gen_ptw_pmp_check
    friscv_pmp_check #(
        .PmpEntries ( PmpEntries )
    ) i_pmp_chk_ptw (
        .pa_i        ( walk_addr     ),
        .access_r_i  ( walk_req      ),
        .access_w_i  ( 1'b0          ),
        .access_x_i  ( 1'b0          ),
        .mode_i      ( S_MODE        ),
        .pmp_table_i ( pmp_table_i   ),
        .fault_o     ( ptw_pmp_fault )
    );
end else begin : gen_no_ptw_pmp_check
    assign ptw_pmp_fault = 1'b0;
end

/////////////////////////////////////
// Permission Check (TLB hit path) //
/////////////////////////////////////

logic perm_inst_ok, perm_load_ok, perm_store_ok;
logic perm_inst_fault, perm_load_fault, perm_store_fault;
logic perm_fault;

logic inst_pmp_fault, data_pmp_fault;
assign inst_pmp_fault_o = inst_pmp_fault || (ptw_access_fault &&  eff_req_ctx.is_inst);
assign data_pmp_fault_o = data_pmp_fault || (ptw_access_fault && !eff_req_ctx.is_inst);

logic data_read, data_write;
assign data_read  = data_en_i && (!data_store_like_i || (amo_op_i != AMO_NONE));
assign data_write = data_en_i &&   data_store_like_i;

// PMP fault of the access currently granted on the bus
logic grant_pmp_fault;
assign grant_pmp_fault = grant_active && !r_access_busy &&
                         (eff_req_ctx.is_inst ? inst_pmp_fault : data_pmp_fault);

if (EnforcePmp) begin : gen_pmp_check
    friscv_pmp_check #(
        .PmpEntries ( PmpEntries )
    ) i_pmp_chk_inst (
        .pa_i        ( inst_pa        ),
        .access_r_i  ( 1'b0           ),
        .access_w_i  ( 1'b0           ),
        .access_x_i  ( inst_en_i      ),
        .mode_i      ( inst_mode_i    ),
        .pmp_table_i ( pmp_table_i    ),
        .fault_o     ( inst_pmp_fault )
    );

    friscv_pmp_check #(
        .PmpEntries ( PmpEntries )
    ) i_pmp_chk_data (
        .pa_i        ( data_pa        ),
        .access_r_i  ( data_read      ),
        .access_w_i  ( data_write     ),
        .access_x_i  ( 1'b0           ),
        .mode_i      ( data_mode_i    ),
        .pmp_table_i ( pmp_table_i    ),
        .fault_o     ( data_pmp_fault )
    );
end else begin : gen_no_pmp_check
    assign inst_pmp_fault = 1'b0;
    assign data_pmp_fault = 1'b0;
end

// Instruction fetch TLB permission check
assign perm_inst_ok = itlb_perm.x &&
                      itlb_perm.a &&
                      ((eff_req_ctx.mode == U_MODE &&  itlb_perm.u) ||
                       (eff_req_ctx.mode == S_MODE && !itlb_perm.u));

// Load TLB permission check
assign perm_load_ok = (dtlb_perm.r || (eff_req_ctx.mxr && dtlb_perm.x)) &&
                      dtlb_perm.a &&
                      ((eff_req_ctx.mode == U_MODE &&  dtlb_perm.u) ||
                       (eff_req_ctx.mode == S_MODE && (!dtlb_perm.u || eff_req_ctx.sum)));

// Store TLB permission check
assign perm_store_ok = dtlb_perm.w &&
                       dtlb_perm.d &&
                       dtlb_perm.a &&
                       ((eff_req_ctx.mode == U_MODE &&  dtlb_perm.u) ||
                        (eff_req_ctx.mode == S_MODE && (!dtlb_perm.u || eff_req_ctx.sum)));

// Perm fault: paging on, arbiter granted, TLB hit, but permission denied
assign perm_inst_fault  = paging_en &&
                          grant_active &&
                          eff_req_ctx.is_inst &&
                          itlb_hit &&
                          !perm_inst_ok &&
                          !tlate_pending &&
                          !r_access_busy;

assign perm_load_fault  = paging_en &&
                          grant_active &&
                          !eff_req_ctx.is_inst &&
                          !eff_req_ctx.is_write &&
                          dtlb_hit && !perm_load_ok &&
                          !tlate_pending &&
                          !r_access_busy;

assign perm_store_fault = paging_en &&
                          grant_active &&
                          !eff_req_ctx.is_inst &&
                          eff_req_ctx.is_write &&
                          dtlb_hit &&
                          !perm_store_ok &&
                          !tlate_pending &&
                          !r_access_busy;

assign perm_fault       = perm_inst_fault | perm_load_fault | perm_store_fault;

// Final fault outputs: PTW structural faults OR perm faults
// PTW faults only if TLB miss, perm faults only if TLB hit - mutually exclusive
assign inst_fault_o  = ptw_inst_fault  || perm_inst_fault;
assign load_fault_o  = ptw_load_fault  || perm_load_fault;
assign store_fault_o = ptw_store_fault || perm_store_fault;
assign fault_addr_o  = (ptw_inst_fault || ptw_load_fault || ptw_store_fault)
                     ? ptw_fault_addr : eff_req_ctx.addr;

///////////////////////////
// PTW / Arbiter Bus Mux //
///////////////////////////

// Physical address for the granted request
ppn_t granted_ppn;
assign granted_ppn = eff_req_ctx.is_inst ? itlb_ppn : dtlb_ppn;

addr_t granted_pa;
assign tlate_pa   = paging_en ? {granted_ppn[PA_PPN_W-1:0], eff_req_ctx.addr[11:0]}
                              : eff_req_ctx.addr;
assign granted_pa = r_access_busy ? r_access_pa : tlate_pa;

assign inst_err_o = l1_inst_err;
assign data_err_o = l1_data_err;

// PTW walk signals routed directly to/from external memory
assign walk_rdata = mem_rdata_i;
assign walk_wait  = mem_wait_i;
assign walk_err   = mem_err_i;

// Stall arbiter while PTW is active, memory stalls, or the registered
assign stall = ptw_stall | (mem_wait_i & (mem_rw_o != RW_IDLE)) | tlate_pending;

// Suppress physical memory access on TLB miss (PTW takes over), perm fault,
// PMP fault, or while the translation is still not ready
assign mem_rw_o    = walk_en ? RW_READ :
                     (tlb_miss | perm_fault | grant_pmp_fault | tlate_pending) ? RW_IDLE :
                     grant_rw;

assign mem_addr_o  = walk_en ? walk_addr : granted_pa;
assign mem_size_o  = walk_en ? WIDTH_I32 : grant_size;
assign mem_wdata_o = walk_en ? '0        : grant_wdata;
assign amo_op_o    = walk_en ? AMO_NONE  : grant_amo;

endmodule

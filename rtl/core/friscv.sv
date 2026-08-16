// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

module friscv import friscv_pkg::*, friscv_mem_pkg::*; #(
    parameter int unsigned HartId           = 0,
    parameter int unsigned ResetVec         = 32'h8000_0000,
    parameter int unsigned DmBase           = 32'h0000_0000,
    parameter int unsigned DmHaltOffset     = 32'h800,
    parameter int unsigned DmExcOffset      = 32'h810,

    // Memory protection and address translation
    parameter bit EnableMmu     = 1,
    parameter bit EnforcePmp    = 0,
    parameter bit EnforcePtwPmp = 0,
    parameter int unsigned PmpEntries  = 8,
    parameter int unsigned PmpUsable   = 8,
    // Must be a power of 2 greater than 1
    parameter int unsigned ItlbEntries = 2,
    parameter int unsigned DtlbEntries = 4,
    // If not enabled, any sfence.vma will flush all TLB entries
    parameter bit EnableFineTlbFlush = 0,

    // Extension selection
    parameter bit EnableIsaE    = 0,
    parameter bit EnableIsaM    = 1,
    // Use a single-cycle combinational multiplier instead of the iterative multiplier
    parameter bit EnableFastMul = 0,
    parameter bit EnableIsaA    = 1,
    // If enabled, a write to END_ADDRESS will stall the core until reset
    parameter bit HaltOnEndAddress = 0,
    // If enabled, entering an EBREAK instruction will halt the core until reset
    parameter bit HaltOnEnterEbreak = 0,
    // If enabled, the first MRET or SRET after entering an EBREAK handler will halt the core until reset
    parameter bit HaltOnRetFromEbreak = 0
) (
    input  logic            clk_i,
    input  logic            rst_ni,
    output logic            end_o,
    input  logic            msip_i,
    input  logic            mtip_i,
    input  logic            meip_i,
    input  logic            seip_i,
    input  mtime_t          mtime_i,

    output friscv_mem_req_t mem_req_o,
    input  friscv_mem_rsp_t mem_rsp_i,

    input  logic            dbg_req_i
);

mem_width_e mem_size;
addr_t      mem_addr;
data_t      mem_wdata;
rw_cmd_e    mem_rw;

data_t mem_rdata;
logic  mem_wait;
logic  mem_err;

assign mem_rdata = mem_rsp_i.rdata;
assign mem_wait  = mem_rsp_i.stall;
assign mem_err   = mem_rsp_i.err;

// Elaboration-time parameter checks
if (!EnableIsaM && EnableFastMul) begin : gen_chk_fast_mul_has_mul
    $fatal(1, "EnableFastMul enabled, but EnableIsaM disabled. Fast multiplier requires M extension.");
end
if (!EnableMmu && EnforcePmp) begin : gen_chk_pmp_requires_mmu
    $fatal(1, "EnforcePmp enabled, but EnableMmu disabled. PMP enforcement requires MMU.");
end
if (!EnforcePmp && EnforcePtwPmp) begin : gen_chk_ptw_pmp_requires_pmp
    $fatal(1, "EnforcePtwPmp enabled, but EnforcePmp disabled. PTW PMP enforcement requires PMP enforcement.");
end
if (PmpUsable > PmpEntries) begin : gen_chk_pmp_usable_le_entries
    $fatal(1, "PmpUsable (%0d) exceeds PmpEntries (%0d).", PmpUsable, PmpEntries);
end
if (PmpEntries > 64) begin : gen_chk_pmp_entries_le_64
    $fatal(1, "PmpEntries (%0d) exceeds the maximum of 64.", PmpEntries);
end

// ============================================================
// Level 1 bus: instruction and data memory interfaces
// ============================================================

// Instruction L1 bus
addr_t      inst_addr;
data_t      inst_data;
logic       inst_en;
logic       inst_wait;
logic       inst_err;
logic       stall_if;

// Data L1 bus
addr_t      data_addr;
data_t      data_wdata;
data_t      data_rdata;
logic       data_en;
logic       data_wr;
logic       data_store_like;
mem_width_e data_size;
logic       data_wait;
logic       data_err;
amo_op_e    amo_op;
logic       ex_mem_inflight;

// ============================================================
// Protection and Translation signals
// ============================================================

satp_t satp;
logic  sum;
logic  mxr;
mode_e mode;
mode_e data_mode;
logic  flush_tlb;
vpn_t  flush_vpn;
logic  flush_vpn_en;
asid_t flush_asid;
logic  flush_asid_en;

// ============================================================
// Level 2 bus and L1-L2 arbitration
// ============================================================

addr_t      l2_req_addr;
mem_width_e l2_req_size;
data_t      l2_req_wdata;
rw_cmd_e    l2_req_rw;
data_t      l2_req_rdata;
logic       l2_req_wait;
logic       l2_req_err;
amo_op_e    l2_req_amo_op;

addr_t      l2_addr;
mem_width_e l2_size;
data_t      l2_wdata;
rw_cmd_e    l2_rw;
data_t      l2_backend_rdata;
logic       l2_backend_wait;
logic       l2_backend_err;
amo_op_e    l2_amo_op;

// AMO unit signals
rw_cmd_e    amo_rw;
data_t      amo_store_data;
data_t      amo_load_data;
logic       amo_core_wait;
logic       amo_active;
logic       amo_start;
logic       amo_bootstrap;
logic       r_amo_addr_valid;
addr_t      r_amo_addr;
mem_width_e r_amo_size;

assign amo_start = (l2_amo_op != AMO_NONE) &&
                    (l2_rw != RW_IDLE) &&
                    !r_amo_addr_valid;
assign amo_bootstrap = (l2_amo_op != AMO_NONE) && !r_amo_addr_valid;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        r_amo_addr_valid <= 1'b0;
        r_amo_addr       <= '0;
        r_amo_size       <= WIDTH_I32;
    end else begin
        // Freeze AMO target address and size for the whole LOAD-STORE sequence
        if (amo_start) begin
            r_amo_addr_valid <= 1'b1;
            r_amo_addr       <= l2_addr;
            r_amo_size       <= l2_size;
        end else if (r_amo_addr_valid && amo_rw == RW_IDLE) begin
            r_amo_addr_valid <= 1'b0;
        end
    end
end

assign mem_size  = amo_active ? (r_amo_addr_valid ? r_amo_size : l2_size) : l2_size;
assign mem_addr  = amo_active ? (r_amo_addr_valid ? r_amo_addr : l2_addr) : l2_addr;
assign mem_wdata = amo_active ? amo_store_data : l2_wdata;

// Page fault signals
logic  inst_fault, load_fault, store_fault;
addr_t fault_addr;

pmp_entry_t [PmpEntries-1:0] pmp_table;
logic inst_pmp_fault, data_pmp_fault;

// The MMU contains an arbiter.
// If the MMU is disabled, a bare arbiter is instantiated instead.
`pragma diagnostic push
`pragma diagnostic ignore="-Wempty-output-connection"
if (EnableMmu) begin : gen_mmu
    friscv_mmu #(
        .EnforcePmp         ( EnforcePmp         ),
        .EnforcePtwPmp      ( EnforcePtwPmp      ),
        .PmpEntries         ( PmpEntries         ),
        .ItlbEntries        ( ItlbEntries        ),
        .DtlbEntries        ( DtlbEntries        ),
        .EnableFineTlbFlush ( EnableFineTlbFlush )
    ) i_mmu (
        .i_clk           ( clk_i         ),
        .i_rstn          ( rst_ni        ),

        // Instruction Memory Interface
        .i_inst_addr     ( inst_addr     ),
        .o_inst_data     ( inst_data     ),
        .i_inst_en       ( inst_en       ),
        .o_inst_wait     ( inst_wait     ),
        .o_inst_err      ( inst_err      ),
        .o_inst_pmp_fault( inst_pmp_fault),

        // Data Memory Interface
        .i_data_addr     ( data_addr     ),
        .i_data_size     ( data_size     ),
        .i_data_wdata    ( data_wdata    ),
        .o_data_rdata    ( data_rdata    ),
        .i_data_en       ( data_en       ),
        .i_data_wr       ( data_wr       ),
        .i_data_store_like ( data_store_like ),
        .o_data_wait     ( data_wait     ),
        .o_data_err      ( data_err      ),
        .o_data_pmp_fault( data_pmp_fault),
        .i_amo_op        ( amo_op        ),

        // External Memory Interface
        .o_mem_size      ( l2_req_size   ),
        .o_mem_addr      ( l2_req_addr   ),
        .o_mem_wdata     ( l2_req_wdata  ),
        .i_mem_rdata     ( l2_req_rdata  ),
        .o_mem_rw        ( l2_req_rw     ),
        .i_mem_wait      ( l2_req_wait   ),
        .i_mem_err       ( l2_req_err    ),
        .o_amo_op        ( l2_req_amo_op ),

        // Protection and Translation Control
        .i_satp          ( satp          ),
        .i_sum           ( sum           ),
        .i_mxr           ( mxr           ),
        .i_inst_mode     ( mode          ),
        .i_data_mode     ( data_mode     ),
        .i_flush_tlb     ( flush_tlb     ),
        .i_flush_vpn     ( flush_vpn     ),
        .i_flush_vpn_en  ( flush_vpn_en  ),
        .i_flush_asid    ( flush_asid    ),
        .i_flush_asid_en ( flush_asid_en ),
        .i_pmp_table     ( pmp_table     ),

        // Page fault signals
        .o_inst_fault    ( inst_fault    ),
        .o_load_fault    ( load_fault    ),
        .o_store_fault   ( store_fault   ),
        .o_fault_addr    ( fault_addr    )
    );
end else begin : gen_no_mmu
    friscv_arbiter i_arbiter (
        .i_clk        ( clk_i         ),
        .i_rstn       ( rst_ni        ),

        .i_inst_addr  ( inst_addr     ),
        .o_inst_data  ( inst_data     ),
        .i_inst_en    ( inst_en       ),
        .o_inst_wait  ( inst_wait     ),
        .o_inst_err   ( inst_err      ),

        .i_data_addr  ( data_addr     ),
        .i_data_size  ( data_size     ),
        .i_data_wdata ( data_wdata    ),
        .o_data_rdata ( data_rdata    ),
        .i_data_en    ( data_en       ),
        .i_data_wr    ( data_wr       ),
        .o_data_wait  ( data_wait     ),
        .o_data_err   ( data_err      ),
        .i_amo_op     ( amo_op        ),

        .o_mem_addr   ( l2_req_addr   ),
        .o_mem_size   ( l2_req_size   ),
        .o_mem_wdata  ( l2_req_wdata  ),
        .i_mem_rdata  ( l2_req_rdata  ),
        .o_mem_rw     ( l2_req_rw     ),
        .i_mem_wait   ( l2_req_wait   ),
        .i_mem_err    ( l2_req_err    ),
        .o_amo_op     ( l2_req_amo_op ),
        .o_grant_start(               ),
        .o_grant_start_inst(          ),
        .o_grant_held (               )
    );

    assign inst_fault  = 1'b0;
    assign load_fault  = 1'b0;
    assign store_fault = 1'b0;
    assign fault_addr  = '0;
    assign inst_pmp_fault = 1'b0;
    assign data_pmp_fault = 1'b0;
end
`pragma diagnostic pop

// ============================================================
// Level 2 bus
// ============================================================

assign l2_addr   = l2_req_addr;
assign l2_size   = l2_req_size;
assign l2_wdata  = l2_req_wdata;
assign l2_rw     = l2_req_rw;
assign l2_amo_op = (l2_req_rw != RW_IDLE) ? l2_req_amo_op : AMO_NONE;

assign l2_req_wait  = l2_backend_wait;
assign l2_req_err   = l2_backend_err;
assign l2_req_rdata = l2_backend_rdata;

// ============================================================
// End signal detection on write to END_ADDRESS
// ============================================================

logic end_signal_q;
logic halt_active_q;
logic w_core_halt;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        end_signal_q  <= 1'b0;
        halt_active_q <= 1'b0;
    end else if (HaltOnEndAddress && data_addr == END_ADDRESS && data_en && data_wr) begin
        end_signal_q  <= 1'b1;
        halt_active_q <= 1'b1;
    end else begin
        if (w_core_halt)
            halt_active_q <= 1'b1;
        if (halt_active_q && !ex_mem_inflight && !data_en)
            end_signal_q <= 1'b1;
    end
end

assign end_o = end_signal_q;
assign stall_if = inst_wait;

// ============================================================
// Core instance
// ============================================================

friscv_datapath #(
    .HartId              ( HartId              ),
    .ResetVec            ( ResetVec            ),
    .DmBase              ( DmBase              ),
    .DmHaltOffset        ( DmHaltOffset        ),
    .DmExcOffset         ( DmExcOffset         ),
    .EnableMmu           ( EnableMmu           ),
    .EnforcePmp          ( EnforcePmp          ),
    .PmpEntries          ( PmpEntries          ),
    .PmpUsable           ( PmpUsable           ),
    .EnableIsaE          ( EnableIsaE          ),
    .EnableIsaM          ( EnableIsaM          ),
    .EnableFastMul       ( EnableFastMul       ),
    .EnableIsaA          ( EnableIsaA          ),
    .HaltOnEnterEbreak   ( HaltOnEnterEbreak   ),
    .HaltOnRetFromEbreak ( HaltOnRetFromEbreak )
) i_datapath (
    .clk_i,
    .rst_ni,
    .halt_o           ( w_core_halt     ),
    .halt_i           ( halt_active_q   ),
    .ex_mem_inflight_o( ex_mem_inflight ),

    // Interrupt requests
    .msip_i,
    .mtip_i,
    .meip_i,
    .seip_i,

    // CLINT time
    .mtime_i,

    // Page fault signals
    .inst_fault_i     ( inst_fault    ),
    .load_fault_i     ( load_fault    ),
    .store_fault_i    ( store_fault   ),
    .fault_addr_i     ( fault_addr    ),

    // Instruction Memory Interface
    .imem_addr_o      ( inst_addr     ),
    .imem_data_i      ( inst_data     ),
    .imem_en_o        ( inst_en       ),
    .imem_wait_i      ( stall_if      ),
    .imem_err_i       ( inst_err      ),
    .imem_pmp_fault_i ( inst_pmp_fault ),

    // Data memory interface
    .dmem_addr_o      ( data_addr     ),
    .dmem_data_o      ( data_wdata    ),
    .dmem_data_i      ( data_rdata    ),
    .dmem_en_o        ( data_en       ),
    .dmem_wr_o        ( data_wr       ),
    .dmem_storelike_o ( data_store_like ),
    .dmem_size_o      ( data_size     ),
    .dmem_wait_i      ( data_wait     ),
    .dmem_err_i       ( data_err      ),
    .dmem_pmp_fault_i ( data_pmp_fault ),
    .dmem_amo_op_o    ( amo_op        ),

    // Memory management outputs
    .satp_o           ( satp          ),
    .sum_o            ( sum           ),
    .mxr_o            ( mxr           ),
    .mode_o           ( mode          ),
    .data_mode_o      ( data_mode     ),
    .flush_tlb_o      ( flush_tlb     ),
    .flush_vpn_o      ( flush_vpn     ),
    .flush_vpn_en_o   ( flush_vpn_en  ),
    .flush_asid_o     ( flush_asid    ),
    .flush_asid_en_o  ( flush_asid_en ),
    .pmp_table_o      ( pmp_table     ),

    .dbg_req_i
);

// ============================================================
// Atomic memory operations
// ============================================================

amo_op_e eff_amo;
assign eff_amo = r_amo_addr_valid ? l2_amo_op : AMO_NONE;

if (EnableIsaA) begin : gen_amo
    friscv_amo_unit i_amo_unit (
        .clk_i,
        .rst_ni,
        .amo_op_i         ( eff_amo        ),
        .rs2_val_i        ( l2_wdata       ),
        .core_load_data_o ( amo_load_data  ),
        .core_wait_o      ( amo_core_wait  ),
        .mem_wait_i       ( mem_wait       ),
        .mem_err_i        ( mem_err        ),
        .mem_rw_o         ( amo_rw         ),
        .mem_load_data_i  ( mem_rdata      ),
        .mem_store_data_o ( amo_store_data )
    );
    // Keep AMO path selected across both LOAD and STORE phases
    assign amo_active = amo_bootstrap || (eff_amo != AMO_NONE) || (amo_rw != RW_IDLE);
end else begin : gen_no_amo
    assign amo_active     = 1'b0;
    assign amo_rw         = RW_IDLE;
    assign amo_store_data = '0;
    assign amo_load_data  = '0;
    assign amo_core_wait  = 1'b0;
    assign amo_bootstrap  = 1'b0;
end

assign l2_backend_rdata = amo_active ? amo_load_data : mem_rdata;

assign l2_backend_wait  = amo_bootstrap ? 1'b1 :
                          amo_active ? amo_core_wait :
                          mem_wait;

assign l2_backend_err = mem_err;

assign mem_rw = amo_bootstrap ? RW_IDLE :
                amo_active ? amo_rw :
                l2_rw;

// ============================================================
// External memory port
// ============================================================

// Signedness is resolved inside the core, dropped here.
logic [1:0] bus_size;
always_comb begin
    case (mem_size)
        WIDTH_I8,  WIDTH_U8:  bus_size = SIZE_BYTE;
        WIDTH_I16, WIDTH_U16: bus_size = SIZE_HALF;
        WIDTH_I32:            bus_size = SIZE_WORD;
        default:              bus_size = SIZE_WORD;
    endcase
end

assign mem_req_o.addr  = mem_addr;
assign mem_req_o.size  = bus_size;
assign mem_req_o.wdata = mem_wdata;
assign mem_req_o.en    = mem_rw != RW_IDLE;
assign mem_req_o.wr    = mem_rw == RW_WRITE;

// No cache, never issues bursts
assign mem_req_o.burst = 1'b0;

endmodule

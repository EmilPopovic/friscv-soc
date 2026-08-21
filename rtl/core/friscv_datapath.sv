// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the FRISC-V core datapath, connecting all pipeline stages.
 * Two memory interfaces are provided, one for instructions and one for data, as well as external interrupt signals.
 * In a multi-core system, make sure that each core has a unique HART_ID, and that one core has HART_ID=0.
 */

module friscv_datapath
    import friscv_pkg::*;
#(
    parameter int unsigned HartId        = 0,
    parameter int unsigned ResetVec      = 32'h8000_0000,
    parameter int unsigned DmBase        = 32'h0000_0000,
    parameter int unsigned DmHaltOffset = 32'h800,
    parameter int unsigned DmExcOffset  = 32'h810,

    // Memory protection and address translation
    parameter bit EnableMmu  = 1,
    parameter bit EnforcePmp = 0,
    parameter int PmpEntries = 8,
    parameter int PmpUsable  = 8,

    // Extension selection
    parameter bit EnableIsaE    = 0,
    parameter bit EnableIsaM    = 1,
    // Use a single-cycle combinational multiplier instead of the iterative multiplier
    parameter bit EnableFastMul = 0,
    parameter bit EnableIsaA    = 1,

    // If enabled, entering an EBREAK instruction will halt the core until reset
    parameter bit HaltOnEnterEbreak = 0,
    // If enabled, the first MRET or SRET after entering an EBREAK handler will halt the core until reset
    parameter bit HaltOnRetFromEbreak = 0
) (
    input  logic       clk_i,
    input  logic       rst_ni,
    output logic       halt_o,
    input  logic       halt_i,
    output logic       ex_mem_inflight_o,

    // Interrupt requests
    input  logic       msip_i,
    input  logic       mtip_i,
    input  logic       meip_i,
    input  logic       seip_i,

    // CLINT time
    input  mtime_t     mtime_i,

    // Page fault signals
    input  logic       inst_fault_i,
    input  logic       load_fault_i,
    input  logic       store_fault_i,
    input  addr_t      fault_addr_i,
    
    // Instruction Memory Interface
    output addr_t      imem_addr_o,
    input  data_t      imem_data_i,
    output logic       imem_en_o,
    input  logic       imem_wait_i,
    input  logic       imem_err_i,
    input  logic       imem_pmp_fault_i,

    // Data memory interface 
    output addr_t      dmem_addr_o,
    output data_t      dmem_data_o,
    input  data_t      dmem_data_i,
    output logic       dmem_en_o,
    output logic       dmem_wr_o,
    output logic       dmem_storelike_o,
    output mem_width_e dmem_size_o,
    input  logic       dmem_wait_i,
    input  logic       dmem_err_i,
    input  logic       dmem_pmp_fault_i,
    output amo_op_e    dmem_amo_op_o,

    // Memory management outputs
    output satp_t      satp_o,
    output logic       sum_o,
    output logic       mxr_o,
    output mode_e      mode_o,
    output mode_e      data_mode_o,
    output logic       flush_tlb_o,
    output vpn_t       flush_vpn_o,
    output logic       flush_vpn_en_o,
    output asid_t      flush_asid_o,
    output logic       flush_asid_en_o,
    output pmp_entry_t [PmpEntries-1:0] pmp_table_o,

    input  logic       dbg_req_i
);

logic flush_if, flush_id;
logic stall_if, stall_id, stall_ex, stall_mem, flush_ex;

// Jump signals
logic  jump_ok, jal_ok, branch_ok;
addr_t jump_target, jal_target;  // ex_alu_data_out is branch_target

// IF stage signals
addr_t if_pc, if_next_pc;
data_t if_ir;
logic  if_discard;

// A discarded fetch drops its fault too
logic  if_fault, if_err, if_pmp_fault;
assign if_fault     = inst_fault_i     && !if_discard;
assign if_err       = imem_err_i       && !if_discard;
assign if_pmp_fault = imem_pmp_fault_i && !if_discard;

// ID stage signals
reg_addr_t id_rs1_sel, id_rs2_sel, id_rd_sel;
addr_t     id_pc, id_next_pc;
data_t     id_rs1, id_rs2, id_imm32, id_csr;    
instr_ex_t id_uinstr;
logic      id_csr_is_ctr;

// EX stage signals
addr_t          ex_pc;
addr_t          ex_next_pc;
data_t          ex_alu_data, ex_store_data;
reg_addr_t      ex_rd_sel;
mem_instr_sel_e ex_mem_instr_sel;
mem_width_e     ex_load_store_width;
wb_data_sel_e   ex_wb_data_sel;
logic           ex_reserve;
logic           ex_conditional;
amo_op_e        ex_amo_op;
csr_addr_e      ex_csr_sel;
data_t          ex_csr_readback;
logic           ex_csr_en;
logic           ex_instr_valid;
logic           ex_muldiv_active;
addr_t          ex_branch_target;
ex_trap_e       ex_trap;
addr_t          ex_trap_pc;
addr_t          ex_trap_va;
mode_e          ex_trap_mode;
logic           ex_commit;
logic           ex_csr_is_ser;

logic ex_instr_is_mem;
assign ex_instr_is_mem = ex_mem_instr_sel != MEM_INSTR_NONE;
assign ex_mem_inflight_o = ex_instr_is_mem;

// MEM stage signals
mem_trap_e      mem_trap;
addr_t          mem_trap_pc;
addr_t          mem_trap_va;
mode_e          mem_trap_mode;
addr_t          mem_next_pc;
data_t          mem_alu_data;
data_t          mem_load_data;
data_t          mem_sc_res;
wb_data_sel_e   mem_wb_data_sel;
reg_addr_t      mem_rd_sel;
csr_addr_e      mem_csr_sel;
data_t          mem_csr_data;
data_t          mem_csr_readback;
logic           mem_csr_en;
logic           mem_instr_valid;
logic           mem_commit;
logic           mem_csr_is_ser;

// WB stage signals
data_t     wb_rd_data;
reg_addr_t wb_rd_sel;
csr_addr_e wb_csr_sel;
data_t     wb_csr_data;
logic      wb_csr_en;
logic      wb_inst_ret;
logic      wb_instr_valid;
logic      wb_csr_is_ser;

// Interrupts
addr_t id_tvec, id_epc;
logic  id_trap, id_trap_pending, id_ret , id_effective_ret;
logic  data_addr_virtual;

assign data_addr_virtual = EnableMmu && (data_mode_o != M_MODE) && (|satp_o.mode);

//////////////////
// Control unit //
//////////////////

friscv_control_unit i_control_unit (
    // Control signals
    .flush_if_o         ( flush_if           ),
    .flush_id_o         ( flush_id           ),
    .flush_ex_o         ( flush_ex           ),
    .stall_if_o         ( stall_if           ),
    .stall_id_o         ( stall_id           ),
    .stall_ex_o         ( stall_ex           ),
    .stall_mem_o        ( stall_mem          ),

    // IF stage
    .jump_ok_o          ( jump_ok            ),
    .jump_target_o      ( jump_target        ),
    .eff_ret_o          ( id_effective_ret   ),  

    // ID stage
    .id_rs1_sel_i       ( id_rs1_sel         ),
    .id_rs2_sel_i       ( id_rs2_sel         ),
    .jal_ok_i           ( jal_ok             ),
    .jal_target_i       ( jal_target         ),
    .id_csr_en_i        ( id_uinstr.csr_op   ),
    .id_csr_sel_i       ( id_uinstr.csr_addr ),
    .id_csr_is_ctr_i    ( id_csr_is_ctr      ),

    // EX stage
    .ex_rd_sel_i        ( ex_rd_sel          ),
    .branch_ok_i        ( branch_ok          ),
    .branch_target_i    ( ex_branch_target   ),
    .ex_csr_en_i        ( ex_csr_en          ),
    .ex_csr_sel_i       ( ex_csr_sel         ),
    .ex_muldiv_active_i ( ex_muldiv_active   ),
    .ex_csr_is_ser_i    ( ex_csr_is_ser      ),

    // MEM stage
    .mem_rd_sel_i       ( mem_rd_sel         ),
    .mem_csr_en_i       ( mem_csr_en         ),
    .mem_csr_sel_i      ( mem_csr_sel        ),
    .mem_csr_is_ser_i   ( mem_csr_is_ser     ),

    // WB stage
    .wb_rd_sel_i        ( wb_rd_sel          ),
    .wb_csr_en_i        ( wb_csr_en          ),
    .wb_csr_sel_i       ( wb_csr_sel         ),
    .ex_instr_valid_i   ( ex_instr_valid     ),
    .mem_instr_valid_i  ( mem_instr_valid    ),
    .wb_instr_valid_i   ( wb_instr_valid     ),
    .wb_csr_is_ser_i    ( wb_csr_is_ser      ),

    // Older memory operations must drain before return redirects take effect
    .ex_mem_inflight_i  ( ex_instr_is_mem    ),
    .mem_mem_inflight_i ( dmem_en_o          ),

    // Memory wait signals
    .imem_wait_i,
    .dmem_wait_i,
    
    // Interrupts
    .trap_i             ( id_trap            ),
    .trap_pending_i     ( id_trap_pending    ),
    .ret_i              ( id_ret             ),

    .halt_i
);

/////////////////////////////
// Instruction Fetch Stage //
/////////////////////////////

friscv_if_stage #(
    .ResetVec ( ResetVec )
) i_if_stage (
    .clk_i,
    .rst_ni,

    // Stage control signals
    .flush_i       ( flush_if         ),
    .stall_i       ( stall_if         ),
    .wait_i        ( imem_wait_i      ),
    .jump_ok_i     ( jump_ok          ),
    .jump_target_i ( jump_target      ),

    // Outputs to ID stage
    .pc_o          ( if_pc            ),
    .next_pc_o     ( if_next_pc       ),
    .ir_o          ( if_ir            ),
    .discard_o     ( if_discard       ),

    // Instruction memory interface
    .mem_addr_o    ( imem_addr_o      ),
    .mem_data_i    ( imem_data_i      ),
    .mem_en_o      ( imem_en_o        ),

    // Interrupts
    .trap_i        ( id_trap          ),
    .ret_i         ( id_effective_ret ),
    .tvec_i        ( id_tvec          ),
    .epc_i         ( id_epc           )
);

//////////////////////////////
// Instruction Decode Stage //
//////////////////////////////

friscv_id_stage #(
    .HartId              ( HartId              ),
    .DmBase              ( DmBase              ),
    .DmHaltOffset        ( DmHaltOffset        ),
    .DmExcOffset         ( DmExcOffset         ),
    .EnableIsaE          ( EnableIsaE          ),
    .EnableIsaM          ( EnableIsaM          ),
    .EnableIsaA          ( EnableIsaA          ),
    .EnforcePmp          ( EnforcePmp          ),
    .PmpEntries          ( PmpEntries          ),
    .PmpUsable           ( PmpUsable           ),
    .HaltOnEnterEbreak   ( HaltOnEnterEbreak   ),
    .HaltOnRetFromEbreak ( HaltOnRetFromEbreak )
) i_id_stage (
    .clk_i, 
    .rst_ni,
    .halt_o,
    .dbg_req_i,

    .branch_ok_i        ( branch_ok        ),
    
    // Interrupt requests
    .msip_i,
    .mtip_i,
    .meip_i,
    .seip_i,

    // CLINT time
    .mtime_i,

    // Page fault signals, from MMU
    .inst_fault_i       ( if_fault         ),
    .fault_addr_i,
    .inst_err_i         ( if_err           ),
    .inst_pmp_fault_i   ( if_pmp_fault     ),

    // Page fault signals, from MEM stage
    .mem_trap_i         ( mem_trap         ),
    .mem_trap_pc_i      ( mem_trap_pc      ),
    .mem_trap_va_i      ( mem_trap_va      ),
    .mem_trap_mode_i    ( mem_trap_mode    ),
    .mem_trap_commit_o  ( mem_commit       ),

    // EX stage trap
    .ex_trap_i          ( ex_trap          ),
    .ex_trap_pc_i       ( ex_trap_pc       ),
    .ex_trap_va_i       ( ex_trap_va       ),
    .ex_trap_mode_i     ( ex_trap_mode     ),
    .ex_trap_commit_o   ( ex_commit        ),

    // Stage control signals
    .flush_i            ( flush_id         ),
    .stall_i            ( stall_id         ),

    // Outputs to control logic
    .rs1_sel_o          ( id_rs1_sel       ),
    .rs2_sel_o          ( id_rs2_sel       ),
    .rd_sel_o           ( id_rd_sel        ),
    .jal_ok_o           ( jal_ok           ),
    .jal_target_o       ( jal_target       ),
    .csr_is_counter_o   ( id_csr_is_ctr    ),

    // Inputs from IF stage
    .pc_i               ( if_pc            ),
    .next_pc_i          ( if_next_pc       ),
    .ir_i               ( if_ir            ),

    // Outputs to EX stage
    .pc_o               ( id_pc            ),
    .next_pc_o          ( id_next_pc       ),
    .rs1_o              ( id_rs1           ),
    .rs2_o              ( id_rs2           ),
    .imm_o              ( id_imm32         ),
    .csr_o              ( id_csr           ),
    .instr_o            ( id_uinstr        ),

    // Inputs from older stages
    .ex_rd_sel_i        ( ex_rd_sel        ),
    .mem_rd_sel_i       ( mem_rd_sel       ),
    .ex_muldiv_active_i ( ex_muldiv_active ),

    // Inputs from WB stage
    .rd_sel_i           ( wb_rd_sel        ),
    .rd_i               ( wb_rd_data       ),
    .csr_sel_i          ( wb_csr_sel       ),
    .csr_data_i         ( wb_csr_data      ),
    .csr_en_i           ( wb_csr_en        ),
    .instr_ret_i        ( wb_inst_ret      ),

    // CSR write-in-flight visibility
    .ex_csr_en_i        ( ex_csr_en        ),
    .mem_csr_en_i       ( mem_csr_en       ),
    .wb_csr_en_i        ( wb_csr_en        ),
    .ex_mem_inflight_i  ( ex_instr_is_mem  ),
    .mem_mem_inflight_i ( dmem_en_o        ),
    
    // Interrupts
    .tvec_o             ( id_tvec          ), 
    .epc_o              ( id_epc           ),
    .trap_o             ( id_trap          ),
    .trap_pending_o     ( id_trap_pending  ),
    .ret_o              ( id_ret           ),
    .ret_commit_i       ( id_effective_ret ),

    // Outputs to MMU
    .satp_o             ( satp_o           ),
    .sum_o              ( sum_o            ),
    .mxr_o              ( mxr_o            ),
    .mode_o             ( mode_o           ),
    .data_mode_o        ( data_mode_o      ),
    .pmp_table_o        ( pmp_table_o      )
);

///////////////////
// Execute Stage //
///////////////////

friscv_ex_stage #(
    .EnableIsaM    ( EnableIsaM    ),
    .EnableFastMul ( EnableFastMul )
) i_ex_stage (
    .clk_i,
    .rst_ni,

    // Stage control signals
    .stall_i            ( stall_ex            ),
    .flush_i            ( flush_ex            ),
    .csr_is_ser_o       ( ex_csr_is_ser       ),

    // Inputs from ID stage
    .pc_i               ( id_pc               ),
    .next_pc_i          ( id_next_pc          ),
    .rs1_i              ( id_rs1              ),
    .rs2_i              ( id_rs2              ),
    .imm32_i            ( id_imm32            ),
    .csr_i              ( id_csr              ),
    .rs1_sel_i          ( id_rs1_sel          ),
    .rs2_sel_i          ( id_rs2_sel          ),
    .rd_sel_i           ( id_rd_sel           ),
    .mode_i             ( mode_o              ),
    .instr_ex_i         ( id_uinstr           ),

    // Outputs to MEM stage
    .pc_o               ( ex_pc               ),
    .next_pc_o          ( ex_next_pc          ),
    .alu_data_o         ( ex_alu_data         ),
    .rd_sel_o           ( ex_rd_sel           ),
    .store_data_o       ( ex_store_data       ),
    .mem_instr_sel_o    ( ex_mem_instr_sel    ),
    .load_store_width_o ( ex_load_store_width ),
    .wb_data_sel_o      ( ex_wb_data_sel      ),
    .reserve_o          ( ex_reserve          ),
    .conditional_o      ( ex_conditional      ),
    .amo_op_o           ( ex_amo_op           ),
    .csr_sel_o          ( ex_csr_sel          ),
    .csr_readback_o     ( ex_csr_readback     ),
    .csr_en_o           ( ex_csr_en           ),
    .instr_valid_o      ( ex_instr_valid      ),
    .mode_o             ( ex_trap_mode        ),

    // Outputs to control logic
    .branch_ok_o        ( branch_ok           ),
    .muldiv_active_o    ( ex_muldiv_active    ),
    .branch_target_o    ( ex_branch_target    ),
    .flush_tlb_o,
    .flush_vpn_o,
    .flush_vpn_en_o,
    .flush_asid_o,
    .flush_asid_en_o,

    // Trap signals
    .trap_commit_i      ( ex_commit           ),
    .trap_o             ( ex_trap             ),
    .trap_pc_o          ( ex_trap_pc          ),
    .trap_va_o          ( ex_trap_va          )
);

//////////////////
// Memory Stage //
//////////////////

friscv_mem_stage i_mem_stage (
    .clk_i,
    .rst_ni,

    // Stage control signals
    .stall_i            ( stall_mem           ),
    .trap_commit_i      ( id_trap             ),
    .addr_virtual_i     ( data_addr_virtual   ),
    .csr_is_ser_o       ( mem_csr_is_ser      ),

    // Inputs from EX stage
    .pc_i               ( ex_pc               ),
    .next_pc_i          ( ex_next_pc          ),
    .alu_data_i         ( ex_alu_data         ),
    .rd_sel_i           ( ex_rd_sel           ),
    .store_data_i       ( ex_store_data       ),
    .mem_instr_sel_i    ( ex_mem_instr_sel    ),
    .load_store_width_i ( ex_load_store_width ),
    .wb_data_sel_i      ( ex_wb_data_sel      ),
    .csr_sel_i          ( ex_csr_sel          ),
    .csr_readback_i     ( ex_csr_readback     ),
    .csr_en_i           ( ex_csr_en           ),
    .csr_is_ser_i       ( ex_csr_is_ser       ),
    .instr_valid_i      ( ex_instr_valid      ),
    .mode_i             ( ex_trap_mode        ),

    // Page fault outputs to ID stage
    .mem_trap_o         ( mem_trap            ),
    .mem_trap_pc_o      ( mem_trap_pc         ),
    .mem_trap_va_o      ( mem_trap_va         ),
    .mem_trap_mode_o    ( mem_trap_mode       ),

    // AMO control
    .reserve_i          ( ex_reserve          ),
    .conditional_i      ( ex_conditional      ),
    .clear_reserve_i    ( mem_commit          ),
    .amo_op_i           ( ex_amo_op           ),

    // Outputs to WB stage
    .next_pc_o          ( mem_next_pc         ),
    .alu_data_o         ( mem_alu_data        ),
    .load_data_o        ( mem_load_data       ),
    .sc_res_o           ( mem_sc_res          ),
    .wb_data_sel_o      ( mem_wb_data_sel     ),
    .rd_sel_o           ( mem_rd_sel          ),
    .csr_sel_o          ( mem_csr_sel         ),
    .csr_data_o         ( mem_csr_data        ),
    .csr_readback_o     ( mem_csr_readback    ),
    .csr_en_o           ( mem_csr_en          ),
    .instr_valid_o      ( mem_instr_valid     ),

    // Page fault inputs from MMU
    .load_fault_i,
    .store_fault_i,
    .fault_addr_i,

    // Data memory interface
    .dmem_addr_o,
    .dmem_data_o,
    .dmem_data_i,
    .dmem_en_o,
    .dmem_wr_o,
    .dmem_storelike_o,
    .dmem_size_o,
    .dmem_wait_i,
    .dmem_err_i,
    .dmem_pmp_fault_i,
    .dmem_amo_op_o
);

/////////////////////
// Writeback Stage //
/////////////////////

friscv_wb_stage i_wb_stage (
    .clk_i,
    .rst_ni,
    .stall_i        ( stall_mem        ),
    .csr_is_ser_o   ( wb_csr_is_ser    ),

    // Inputs from MEM stage
    .next_pc_i      ( mem_next_pc      ),
    .alu_data_i     ( mem_alu_data     ),
    .load_data_i    ( mem_load_data    ),
    .sc_res_i       ( mem_sc_res       ),
    .wb_data_sel_i  ( mem_wb_data_sel  ),
    .rd_sel_i       ( mem_rd_sel       ),
    .csr_sel_i      ( mem_csr_sel      ),
    .csr_data_i     ( mem_csr_data     ),
    .csr_readback_i ( mem_csr_readback ),
    .csr_en_i       ( mem_csr_en       ),
    .csr_is_ser_i   ( mem_csr_is_ser   ),
    .instr_valid_i  ( mem_instr_valid  ),

    // Outputs to ID stage
    .rd_data_o      ( wb_rd_data       ),
    .rd_sel_o       ( wb_rd_sel        ),
    .csr_sel_o      ( wb_csr_sel       ),
    .csr_data_o     ( wb_csr_data      ),
    .csr_en_o       ( wb_csr_en        ),
    .instr_valid_o  ( wb_instr_valid   ),
    .inst_ret_o     ( wb_inst_ret      )
);

endmodule

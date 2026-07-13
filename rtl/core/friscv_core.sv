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

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_core #(
    parameter int unsigned HART_ID        = 0,
    parameter int unsigned RESET_VEC      = 32'h8000_0000,
    parameter int unsigned DM_BASE        = 32'h0000_0000,
    parameter int unsigned DM_HALT_OFFSET = 32'h800,
    parameter int unsigned DM_EXC_OFFSET  = 32'h810,

    // Memory protection and address translation
    parameter logic ENABLE_MMU  = 1,
    parameter logic ENFORCE_PMP = 0,
    parameter int   PMP_ENTRIES = 64,
    parameter int   PMP_USABLE  = 64,

    // Extension selection
    parameter logic ENABLE_MUL = 1,
    parameter logic ENABLE_DIV = 1,
    // Use a single-cycle combinational multiplier instead of the iterative multiplier
    parameter logic ENABLE_FAST_MUL = 0,
    parameter logic ENABLE_EXTENSION_A = 1,

    // If enabled, entering an EBREAK instruction will halt the core until reset
    parameter logic ENABLE_HALT_ON_ENTER_EBREAK = 0,
    // If enabled, the first MRET or SRET after entering an EBREAK handler will halt the core until reset
    parameter logic ENABLE_HALT_ON_RET_FROM_EBREAK = 0
) (
    input  logic       i_clk,
    input  logic       i_rstn,
    output logic       o_halt,
    input  logic       i_halt,
    output logic       o_ex_mem_inflight,

    // Interrupt requests
    input  logic       i_msip,
    input  logic       i_mtip,
    input  logic       i_meip,
    input  logic       i_seip,

    // CLINT time
    input  mtime_t     i_mtime,

    // Page fault signals
    input  logic       i_inst_fault,
    input  logic       i_load_fault,
    input  logic       i_store_fault,
    input  addr_t      i_fault_addr,
    
    // Instruction Memory Interface
    output addr_t      i_mem_addr_out,
    input  data_t      i_mem_data_in,
    output logic       i_mem_en_out,
    input  logic       i_mem_wait_in,
    input  logic       i_mem_err_in,
    input  logic       i_mem_pmp_fault_in,

    // Data memory interface 
    output addr_t      d_mem_addr_out,
    output data_t      d_mem_data_out,
    input  data_t      d_mem_data_in,
    output logic       d_mem_en_out,
    output logic       d_mem_wr_out,
    output logic       d_mem_store_like_out,
    output mem_width_e d_mem_size_out,
    input  logic       d_mem_wait_in,
    input  logic       d_mem_err_in,
    input  logic       d_mem_pmp_fault_in,
    output amo_op_e    d_mem_amo_op_out,

    // Memory management outputs
    output satp_t      satp_out,
    output logic       sum_out,
    output logic       mxr_out,
    output mode_e      mode_out,
    output mode_e      data_mode_out,
    output logic       flush_tlb_out,
    output vpn_t       flush_vpn_out,
    output logic       flush_vpn_en_out,
    output asid_t      flush_asid_out,
    output logic       flush_asid_en_out,
    output pmp_entry_t [PMP_ENTRIES-1:0] pmp_table_out,

    input  logic       dbg_req_in
);

logic flush_if, flush_id;
logic stall_if, stall_id, stall_ex, stall_mem, stall_wb, flush_ex;

// Jump signals
logic  jump_ok, jal_ok, branch_ok;
addr_t jump_target, jal_target;  // ex_alu_data_out is branch_target

// IF stage signals
addr_t if_pc_out, if_pc_plus_4_out;
data_t if_ir_out;

// ID stage signals
reg_addr_t id_rs1_sel_out, id_rs2_sel_out, id_rd_sel_out;
addr_t     id_pc_out, id_pc_plus_4_out;
data_t     id_rs1_out, id_rs2_out, id_imm32_out, id_csr_out;    
instr_ex_t id_uinstr;

// EX stage signals
addr_t          ex_pc_out;
addr_t          ex_pc_plus_4_out;
data_t          ex_alu_data_out, ex_store_data_out;
reg_addr_t      ex_rd_sel_out;
mem_instr_sel_e ex_mem_instr_sel_out;
mem_width_e     ex_load_store_width_out;
wb_data_sel_e   ex_wb_data_sel_out;
logic           ex_reserve_out;
logic           ex_conditional_out;
amo_op_e        ex_amo_op_out;
csr_addr_e      ex_csr_sel_out;
data_t          ex_csr_readback_out;
logic           ex_csr_en_out;
logic           ex_instr_valid_out;
logic           ex_muldiv_active;
addr_t          ex_branch_target;
ex_trap_e       ex_trap_out;
addr_t          ex_trap_pc_out;
addr_t          ex_trap_va_out;
mode_e          ex_trap_mode_out;
logic           ex_commit;

logic ex_instr_is_mem;
assign ex_instr_is_mem = ex_mem_instr_sel_out != MEM_INSTR_NONE;
assign o_ex_mem_inflight = ex_instr_is_mem;

// MEM stage signals
mem_trap_e      mem_trap_out;
addr_t          mem_trap_pc_out;
addr_t          mem_trap_va_out;
mode_e          mem_trap_mode_out;
addr_t          mem_pc_plus_4_out;
data_t          mem_alu_data_out;
data_t          mem_load_data_out;
data_t          mem_sc_res_out;
wb_data_sel_e   mem_wb_data_sel_out;
reg_addr_t      mem_rd_sel_out;
csr_addr_e      mem_csr_sel_out;
data_t          mem_csr_data_out;
data_t          mem_csr_readback_out;
logic           mem_csr_en_out;
logic           mem_instr_valid_out;
logic           mem_commit;

// WB stage signals
data_t     wb_rd_data_out;
reg_addr_t wb_rd_sel_out;
csr_addr_e wb_csr_sel_out;
data_t     wb_csr_data_out;
logic      wb_csr_en_out;
logic      wb_inst_ret_out;
logic      wb_instr_valid_out;

// Interrupts
addr_t id_tvec_out, id_epc_out;
logic  id_trap_out, id_trap_pending, id_ret_out , id_effective_ret;
logic  data_addr_virtual;

assign data_addr_virtual = ENABLE_MMU && (data_mode_out != M_MODE) && (|satp_out.mode);

friscv_pipeline_control control_unit (
    // Control signals
    .flush_if_out     ( flush_if           ),
    .flush_id_out     ( flush_id           ),
    .flush_ex_out     ( flush_ex           ),
    .stall_if_out     ( stall_if           ),
    .stall_id_out     ( stall_id           ),
    .stall_ex_out     ( stall_ex           ),
    .stall_mem_out    ( stall_mem          ),

    // IF stage
    .jump_ok_out      ( jump_ok            ),
    .jump_target_out  ( jump_target        ),
    .eff_ret_out      ( id_effective_ret   ),  

    // ID stage
    .id_rs1_sel_in    ( id_rs1_sel_out     ),
    .id_rs2_sel_in    ( id_rs2_sel_out     ),
    .jal_ok_in        ( jal_ok             ),
    .jal_target_in    ( jal_target         ),
    .id_csr_en_in     ( id_uinstr.csr_op   ),
    .id_csr_sel_in    ( id_uinstr.csr_addr ),

    // EX stage
    .ex_rd_sel_in     ( ex_rd_sel_out      ),
    .branch_ok_in     ( branch_ok          ),
    .branch_target_in ( ex_branch_target   ),
    .ex_csr_en_in     ( ex_csr_en_out      ),
    .ex_csr_sel_in    ( ex_csr_sel_out     ),
    .ex_muldiv_active_in ( ex_muldiv_active ),

    // MEM stage
    .mem_rd_sel_in    ( mem_rd_sel_out     ),
    .mem_csr_en_in    ( mem_csr_en_out     ),
    .mem_csr_sel_in   ( mem_csr_sel_out    ),

    // WB stage
    .wb_rd_sel_in     ( wb_rd_sel_out      ),
    .wb_csr_en_in     ( wb_csr_en_out      ),
    .wb_csr_sel_in    ( wb_csr_sel_out     ),
    .ex_instr_valid_in ( ex_instr_valid_out ),
    .mem_instr_valid_in( mem_instr_valid_out),
    .wb_instr_valid_in ( wb_instr_valid_out ),

    // Older memory operations must drain before return redirects take effect
    .ex_mem_inflight_in ( ex_instr_is_mem  ),
    .mem_mem_inflight_in( d_mem_en_out     ),

    // Memory wait signals
    .if_wait_in       ( i_mem_wait_in      ),
    .mem_wait_in      ( d_mem_wait_in      ),
    
    // Interrupts
    .trap_in          ( id_trap_out        ),
    .trap_pending_in  ( id_trap_pending    ),
    .ret_in           ( id_ret_out         ),

    .halt_in          ( i_halt             )
);

friscv_if_stage #(
    .RESET_VEC ( RESET_VEC )
) if_stage (
    .clk_in         ( i_clk             ),
    .rst_n_in       ( i_rstn            ),

    // Stage control signals
    .flush_in       ( flush_if          ),
    .stage_stall_in ( stall_if          ),
    .i_mem_wait_in  ( i_mem_wait_in     ),
    .jump_ok_in     ( jump_ok           ),
    .jump_target_in ( jump_target       ),

    // Outputs to ID stage
    .pc_out         ( if_pc_out         ),
    .pc_plus_4_out  ( if_pc_plus_4_out  ),
    .ir_out         ( if_ir_out         ),

    // Instruction memory interface
    .i_mem_addr_out ( i_mem_addr_out    ),
    .i_mem_data_in  ( i_mem_data_in     ),
    .i_mem_en_out   ( i_mem_en_out      ),

    // Interrupts
    .trap_in        ( id_trap_out       ),
    .ret_in         ( id_effective_ret  ),
    .tvec_in        ( id_tvec_out       ),
    .epc_in         ( id_epc_out        )
);

friscv_id_stage #(
    .HART_ID        ( HART_ID        ),
    .DM_BASE        ( DM_BASE        ),
    .DM_HALT_OFFSET ( DM_HALT_OFFSET ),
    .DM_EXC_OFFSET  ( DM_EXC_OFFSET  ),

    .ENABLE_MUL                     ( ENABLE_MUL                     ),
    .ENABLE_DIV                     ( ENABLE_DIV                     ),
    .ENABLE_EXTENSION_A             ( ENABLE_EXTENSION_A             ),
    .ENFORCE_PMP                    ( ENFORCE_PMP                    ),
    .PMP_ENTRIES                    ( PMP_ENTRIES                    ),
    .PMP_USABLE                     ( PMP_USABLE                     ),
    .ENABLE_HALT_ON_ENTER_EBREAK    ( ENABLE_HALT_ON_ENTER_EBREAK    ),
    .ENABLE_HALT_ON_RET_FROM_EBREAK ( ENABLE_HALT_ON_RET_FROM_EBREAK )
) id_stage (
    .clk_in           ( i_clk            ), 
    .rst_n_in         ( i_rstn           ),
    .halt_out         ( o_halt           ),
    .dbg_req_in       ( dbg_req_in       ),

    .branch_ok_in     ( branch_ok        ),
    
    // Interrupt requests
    .msip_in          ( i_msip           ),
    .mtip_in          ( i_mtip           ),
    .meip_in          ( i_meip           ),
    .seip_in          ( i_seip           ),

    // CLINT time
    .mtime_in         ( i_mtime          ),

    // Page fault signals, from MMU
    .inst_fault_in    ( i_inst_fault     ),
    .fault_addr_in    ( i_fault_addr     ),
    .inst_err_in      ( i_mem_err_in     ),
    .inst_pmp_fault_in( i_mem_pmp_fault_in ),

    // Page fault signals, from MEM stage
    .mem_trap_in      ( mem_trap_out     ),
    .mem_trap_pc_in   ( mem_trap_pc_out  ),
    .mem_trap_va_in   ( mem_trap_va_out  ),
    .mem_trap_mode_in ( mem_trap_mode_out),
    .mem_trap_commit_out ( mem_commit    ),

    // EX stage trap
    .ex_trap_in       ( ex_trap_out      ),
    .ex_trap_pc_in    ( ex_trap_pc_out   ),
    .ex_trap_va_in    ( ex_trap_va_out   ),
    .ex_trap_mode_in  ( ex_trap_mode_out ),
    .ex_trap_commit_out ( ex_commit      ),

    // Stage control signals
    .flush_in         ( flush_id         ),
    .stage_stall_in   ( stall_id         ),

    // Outputs to control logic
    .rs1_sel_out      ( id_rs1_sel_out   ),
    .rs2_sel_out      ( id_rs2_sel_out   ),
    .rd_sel_out       ( id_rd_sel_out    ),
    .jal_ok_out       ( jal_ok           ),
    .jal_target_out   ( jal_target       ),

    // Inputs from IF stage
    .pc_in            ( if_pc_out        ),
    .pc_plus_4_in     ( if_pc_plus_4_out ),
    .ir_in            ( if_ir_out        ),

    // Outputs to EX stage
    .pc_out           ( id_pc_out        ),
    .pc_plus_4_out    ( id_pc_plus_4_out ),
    .rs1_out          ( id_rs1_out       ),
    .rs2_out          ( id_rs2_out       ),
    .imm32_out        ( id_imm32_out     ),
    .csr_out          ( id_csr_out       ),
    .instr_ex_out     ( id_uinstr        ),

    // Inputs from older stages
    .ex_rd_sel_in     ( ex_rd_sel_out    ),
    .mem_rd_sel_in    ( mem_rd_sel_out   ),
    .ex_muldiv_active_in ( ex_muldiv_active ),

    // Inputs from WB stage
    .rd_sel_in        ( wb_rd_sel_out    ),
    .rd_data_in       ( wb_rd_data_out   ),
    .csr_sel_in       ( wb_csr_sel_out   ),
    .csr_data_in      ( wb_csr_data_out  ),
    .csr_en_in        ( wb_csr_en_out    ),
    .instr_ret_in     ( wb_inst_ret_out  ),

    // CSR write-in-flight visibility
    .ex_csr_en_in     ( ex_csr_en_out    ),
    .mem_csr_en_in    ( mem_csr_en_out   ),
    .wb_csr_en_in     ( wb_csr_en_out    ),
    .ex_mem_inflight_in( ex_instr_is_mem ),
    .mem_mem_inflight_in( d_mem_en_out   ),
    
    // Interrupts
    .tvec_out         ( id_tvec_out      ), 
    .epc_out          ( id_epc_out       ),
    .trap_out         ( id_trap_out      ),
    .trap_pending_out ( id_trap_pending  ),
    .ret_out          ( id_ret_out       ),
    .ret_commit_in    ( id_effective_ret ),

    // Outputs to MMU
    .satp_out         ( satp_out         ),
    .sum_out          ( sum_out          ),
    .mxr_out          ( mxr_out          ),
    .mode_out         ( mode_out         ),
    .data_mode_out    ( data_mode_out    ),
    .pmp_table_out    ( pmp_table_out    )
);

friscv_ex_stage #(
    .ENABLE_MUL      ( ENABLE_MUL      ),
    .ENABLE_DIV      ( ENABLE_DIV      ),
    .ENABLE_FAST_MUL ( ENABLE_FAST_MUL )
) ex_stage (
    .clk_in               ( i_clk                   ),
    .rst_n_in             ( i_rstn                  ),

    // Stage control signals
    .stage_stall_in       ( stall_ex                ),
    .stage_flush_in       ( flush_ex                ),

    // Inputs from ID stage
    .pc_in                ( id_pc_out               ),
    .pc_plus_4_in         ( id_pc_plus_4_out        ),
    .rs1_in               ( id_rs1_out              ),
    .rs2_in               ( id_rs2_out              ),
    .imm32_in             ( id_imm32_out            ),
    .csr_in               ( id_csr_out              ),
    .rs1_sel_in           ( id_rs1_sel_out          ),
    .rs2_sel_in           ( id_rs2_sel_out          ),
    .rd_sel_in            ( id_rd_sel_out           ),
    .mode_in              ( mode_out                ),
    .instr_ex_in          ( id_uinstr               ),

    // Outputs to MEM stage
    .pc_out               ( ex_pc_out               ),
    .pc_plus_4_out        ( ex_pc_plus_4_out        ),
    .alu_data_out         ( ex_alu_data_out         ),
    .rd_sel_out           ( ex_rd_sel_out           ),
    .store_data_out       ( ex_store_data_out       ),
    .mem_instr_sel_out    ( ex_mem_instr_sel_out    ),
    .load_store_width_out ( ex_load_store_width_out ),
    .wb_data_sel_out      ( ex_wb_data_sel_out      ),
    .reserve_out          ( ex_reserve_out          ),
    .conditional_out      ( ex_conditional_out      ),
    .amo_op_out           ( ex_amo_op_out           ),
    .csr_sel_out          ( ex_csr_sel_out          ),
    .csr_readback_out     ( ex_csr_readback_out     ),
    .csr_en_out           ( ex_csr_en_out           ),
    .instr_valid_out      ( ex_instr_valid_out      ),
    .mode_out             ( ex_trap_mode_out        ),

    // Outputs to control logic
    .branch_ok_out        ( branch_ok               ),
    .muldiv_active_out    ( ex_muldiv_active        ),
    .branch_target_out    ( ex_branch_target        ),
    .flush_tlb_out        ( flush_tlb_out           ),
    .flush_vpn_out        ( flush_vpn_out           ),
    .flush_vpn_en_out     ( flush_vpn_en_out        ),
    .flush_asid_out       ( flush_asid_out          ),
    .flush_asid_en_out    ( flush_asid_en_out       ),

    // Trap signals
    .trap_commit_in       ( ex_commit               ),
    .trap_out             ( ex_trap_out             ),
    .trap_pc_out          ( ex_trap_pc_out          ),
    .trap_va_out          ( ex_trap_va_out          )
);

friscv_mem_stage mem_stage (
    .clk_in              ( i_clk                   ),
    .rst_n_in            ( i_rstn                  ),

    // Stage control signals
    .stage_stall_in      ( stall_mem               ),
    .trap_commit_in      ( id_trap_out             ),
    .addr_virtual_in     ( data_addr_virtual       ),

    // Inputs from EX stage
    .pc_in               ( ex_pc_out               ),
    .pc_plus_4_in        ( ex_pc_plus_4_out        ),
    .alu_data_in         ( ex_alu_data_out         ),
    .rd_sel_in           ( ex_rd_sel_out           ),
    .store_data_in       ( ex_store_data_out       ),
    .mem_instr_sel_in    ( ex_mem_instr_sel_out    ),
    .load_store_width_in ( ex_load_store_width_out ),
    .wb_data_sel_in      ( ex_wb_data_sel_out      ),
    .csr_sel_in          ( ex_csr_sel_out          ),
    .csr_readback_in     ( ex_csr_readback_out     ),
    .csr_en_in           ( ex_csr_en_out           ),
    .instr_valid_in      ( ex_instr_valid_out      ),
    .mode_in             ( ex_trap_mode_out        ),

    // Page fault inputs from MMU
    .load_fault_in       ( i_load_fault            ),
    .store_fault_in      ( i_store_fault           ),
    .fault_addr_in       ( i_fault_addr            ),

    // Page fault outputs to ID stage
    .mem_trap_out        ( mem_trap_out            ),
    .mem_trap_pc_out     ( mem_trap_pc_out         ),
    .mem_trap_va_out     ( mem_trap_va_out         ),
    .mem_trap_mode_out   ( mem_trap_mode_out       ),

    // AMO control
    .reserve_in          ( ex_reserve_out          ),
    .conditional_in      ( ex_conditional_out      ),
    .clear_reserve_in    ( mem_commit              ),
    .amo_op_in           ( ex_amo_op_out           ),

    // Outputs to WB stage
    .pc_plus_4_out       ( mem_pc_plus_4_out       ),
    .alu_data_out        ( mem_alu_data_out        ),
    .load_data_out       ( mem_load_data_out       ),
    .sc_res_out          ( mem_sc_res_out          ),
    .wb_data_sel_out     ( mem_wb_data_sel_out     ),
    .rd_sel_out          ( mem_rd_sel_out          ),
    .csr_sel_out         ( mem_csr_sel_out         ),
    .csr_data_out        ( mem_csr_data_out        ),
    .csr_readback_out    ( mem_csr_readback_out    ),
    .csr_en_out          ( mem_csr_en_out          ),
    .instr_valid_out     ( mem_instr_valid_out     ),

    // Data memory interface
    .d_mem_addr_out      ( d_mem_addr_out          ),
    .d_mem_data_out      ( d_mem_data_out          ),
    .d_mem_data_in       ( d_mem_data_in           ),
    .d_mem_en_out        ( d_mem_en_out            ),
    .d_mem_wr_out        ( d_mem_wr_out            ),
    .d_mem_store_like_out ( d_mem_store_like_out   ),
    .d_mem_size_out      ( d_mem_size_out          ),
    .d_mem_wait_in       ( d_mem_wait_in           ),
    .d_mem_err_in        ( d_mem_err_in            ),
    .d_mem_pmp_fault_in  ( d_mem_pmp_fault_in      ),
    .d_mem_amo_op_out    ( d_mem_amo_op_out        )
);

assign stall_wb = stall_mem;

friscv_wb_stage wb_stage (
    .clk_in          ( i_clk                  ),
    .rst_n_in        ( i_rstn                 ),
    .stage_stall_in  ( stall_wb               ),

    // Inputs from MEM stage
    .pc_plus_4_in    ( mem_pc_plus_4_out      ),
    .alu_data_in     ( mem_alu_data_out       ),
    .load_data_in    ( mem_load_data_out      ),
    .sc_res_in       ( mem_sc_res_out         ),
    .wb_data_sel_in  ( mem_wb_data_sel_out    ),
    .rd_sel_in       ( mem_rd_sel_out         ),
    .csr_sel_in      ( mem_csr_sel_out        ),
    .csr_data_in     ( mem_csr_data_out       ),
    .csr_readback_in ( mem_csr_readback_out   ),
    .csr_en_in       ( mem_csr_en_out         ),
    .instr_valid_in  ( mem_instr_valid_out    ),

    // Outputs to ID stage
    .rd_data_out     ( wb_rd_data_out         ),
    .rd_sel_out      ( wb_rd_sel_out          ),
    .csr_sel_out     ( wb_csr_sel_out         ),
    .csr_data_out    ( wb_csr_data_out        ),
    .csr_en_out      ( wb_csr_en_out          ),
    .instr_valid_out ( wb_instr_valid_out     ),
    .inst_ret_out    ( wb_inst_ret_out        )
);

endmodule

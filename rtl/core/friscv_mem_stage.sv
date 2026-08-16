// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the memory stage of the FRISC-V pipeline.
 * It handles memory accesses, load data capture and expansion, LR/SC operations, and page fault handling.
 */

module friscv_mem_stage
    import friscv_pkg::*;
(
    input  logic           clk_i,
    input  logic           rst_ni,

    // Stage control signals
    input  logic           stall_i,
    input  logic           trap_commit_i,
    input  logic           addr_virtual_i,
    output logic           csr_is_ser_o,

    // Inputs from EX stage
    input  addr_t          pc_i,
    input  addr_t          next_pc_i,
    input  data_t          alu_data_i,
    input  reg_addr_t      rd_sel_i,
    input  data_t          store_data_i,
    input  mem_instr_sel_e mem_instr_sel_i,
    input  mem_width_e     load_store_width_i,
    input  wb_data_sel_e   wb_data_sel_i,
    input  csr_addr_e      csr_sel_i,
    input  data_t          csr_readback_i,
    input  logic           csr_en_i,
    input  logic           instr_valid_i,
    input  mode_e          mode_i,
    input  logic           csr_is_ser_i,

    // AMO control
    input  logic           reserve_i,
    input  logic           conditional_i,
    input  logic           clear_reserve_i,
    input  amo_op_e        amo_op_i,

    // Outputs to WB stage
    output addr_t          next_pc_o,
    output data_t          alu_data_o,
    output data_t          load_data_o,
    output data_t          sc_res_o,
    output wb_data_sel_e   wb_data_sel_o,
    output reg_addr_t      rd_sel_o,
    output csr_addr_e      csr_sel_o,
    output data_t          csr_data_o,
    output data_t          csr_readback_o,
    output logic           csr_en_o,
    output logic           instr_valid_o,

    // Page fault inputs from MMU
    input  logic           load_fault_i,
    input  logic           store_fault_i,
    input  addr_t          fault_addr_i,

    // Page fault output to ID stage
    output mem_trap_e      mem_trap_o,
    output addr_t          mem_trap_pc_o,
    output addr_t          mem_trap_va_o,
    output mode_e          mem_trap_mode_o,

    // Data memory interface
    output addr_t          dmem_addr_o,
    output data_t          dmem_data_o,
    input  data_t          dmem_data_i,
    output logic           dmem_en_o,
    output logic           dmem_wr_o,
    output logic           dmem_storelike_o,
    output mem_width_e     dmem_size_o,
    input  logic           dmem_wait_i,
    input  logic           dmem_err_i,
    input  logic           dmem_pmp_fault_i,
    output amo_op_e        dmem_amo_op_o
);

// Input buffers
typedef struct packed {
    addr_t          pc;
    addr_t          next_pc;
    addr_t          alu_data;
    data_t          store_data;
    reg_addr_t      rd_sel;
    mem_instr_sel_e mem_instr_sel;
    mem_width_e     load_store_width;
    wb_data_sel_e   wb_data_sel;
    logic           conditional;
    logic           clear_reserve;
    logic           misaligned;
    amo_op_e        amo_op;
    csr_addr_e      csr_sel;
    data_t          csr_readback;
    logic           csr_en;
    logic           csr_is_serializing;
    logic           instr_valid;
    mode_e          mode;
} mem_pipe_t;

// A NOP instance of the pipeline register struct (mem_pipe_t)
localparam mem_pipe_t MEM_PIPE_BUBBLE = '{
    pc: '0,
    next_pc: '0,
    alu_data: '0,
    store_data: '0,
    rd_sel: 5'b0,
    mem_instr_sel: MEM_INSTR_NONE,
    load_store_width: WIDTH_I32,
    wb_data_sel: WB_DATA_SEL_ALU,
    conditional: 1'b0,
    clear_reserve: 1'b0,
    misaligned: 1'b0,
    amo_op: AMO_NONE,
    csr_sel: CSR_ZERO,
    csr_readback: '0,
    csr_en: 1'b0,
    csr_is_serializing: 1'b0,
    instr_valid: 1'b0,
    mode: M_MODE
};

mem_pipe_t pipe_buff;

// Fault capture
// Set when a fault fires on the memory commit cycle
mem_trap_e r_mem_fault;
addr_t     r_mem_fault_pc;
addr_t     r_mem_fault_va;
mode_e     r_mem_fault_mode;

assign mem_trap_o    = r_mem_fault;
assign mem_trap_pc_o = r_mem_fault_pc;
assign mem_trap_va_o = r_mem_fault_va;
assign mem_trap_mode_o = r_mem_fault_mode;

logic w_page_fault, w_access_fault;
assign w_page_fault = load_fault_i || store_fault_i;
assign w_access_fault = dmem_err_i || dmem_pmp_fault_i;

logic r_mem_active;

logic w_mem_completion_fault;
assign w_mem_completion_fault = r_mem_active &&
                                !dmem_wait_i &&
                                (w_page_fault || w_access_fault || pipe_buff.misaligned );

// CSR passthrough
assign csr_sel_o      = pipe_buff.csr_sel;
assign csr_data_o     = pipe_buff.alu_data;
assign csr_readback_o = pipe_buff.csr_readback;
assign csr_en_o       = pipe_buff.csr_en && !w_mem_completion_fault;
assign csr_is_ser_o   = pipe_buff.csr_is_serializing;

data_t load_data;
data_t load_data_buff;  // Buffered load data

logic r_load_data_valid;  // Flag indicating load data has been captured

logic w_is_mem_instr;
assign w_is_mem_instr = mem_instr_sel_i != MEM_INSTR_NONE;

// Detect if this is a store-like instruction (store, SC, or AMO)
logic w_mem_store_like;
assign w_mem_store_like = (mem_instr_sel_i == MEM_INSTR_STORE) || (amo_op_i != AMO_NONE);

logic r_mem_store_like;
assign r_mem_store_like = (pipe_buff.mem_instr_sel == MEM_INSTR_STORE) || (pipe_buff.amo_op != AMO_NONE);

// Detect if this is an atomic-like instruction (LR/SC or AMO)
logic w_mem_atomic_like;
assign w_mem_atomic_like = reserve_i || conditional_i || (amo_op_i != AMO_NONE);

logic r_mem_atomic_like;
assign r_mem_atomic_like = pipe_buff.clear_reserve || pipe_buff.conditional || (pipe_buff.amo_op != AMO_NONE);

logic w_misaligned_access_fault;
assign w_misaligned_access_fault = addr_virtual_i && w_mem_atomic_like;

logic r_misaligned_access_fault;
assign r_misaligned_access_fault = r_mem_atomic_like;

logic w_mem_misaligned;
always_comb begin
    unique case (load_store_width_i)
        WIDTH_I8, WIDTH_U8:   w_mem_misaligned = 1'b0;
        WIDTH_I16, WIDTH_U16: w_mem_misaligned = alu_data_i[0];
        WIDTH_I32:            w_mem_misaligned = alu_data_i[1:0] != 2'b00;
        default:              w_mem_misaligned = 1'b0;
    endcase
end

// Pass valid flag to WB; suppress same-cycle writeback when a memory op faults.
assign instr_valid_o = pipe_buff.instr_valid && !w_mem_completion_fault;

// Reservation register for AMO LR/SC
logic  reserve_valid;
addr_t reserve_addr;
logic  r_sc_res_valid;
logic  r_sc_res;

// Can execute memory instruction if either
//  1) It is a store conditional instruction with a valid reservation for the requested address or
//  2) It is not a store conditional instruction
logic cond_valid;
logic cond_valid_r;
logic prev_sc_success;

assign prev_sc_success = pipe_buff.instr_valid && pipe_buff.conditional && cond_valid_r;
assign cond_valid = (conditional_i) ? reserve_valid && !prev_sc_success && (reserve_addr == alu_data_i) : 1'b1;

///////////////////
// Input Capture //
///////////////////

// MEM stage always accepts data from EX stage
// Bubbles are inserted by EX sending instructions with rd_sel=0
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        pipe_buff         <= MEM_PIPE_BUBBLE;
        r_mem_active      <= 1'b0;
        r_load_data_valid <= 1'b0;
        load_data_buff    <= '0;
        reserve_valid     <= 1'b0;
        reserve_addr      <= '0;
        r_sc_res_valid    <= 1'b0;
        r_sc_res          <= 1'b0;
        cond_valid_r      <= 1'b0;
        r_mem_fault       <= MEM_TRAP_NONE;
        r_mem_fault_pc    <= '0;
        r_mem_fault_va    <= '0;
        r_mem_fault_mode  <= M_MODE;

    end else begin

        if (clear_reserve_i) begin
            reserve_valid <= 1'b0;
        end

        if (trap_commit_i) begin
            // The fault has been consumed by the trap logic. Keep MEM as a
            // bubble while the earlier pipeline stages redirect to the handler.
            pipe_buff         <= MEM_PIPE_BUBBLE;
            r_mem_active      <= 1'b0;
            r_load_data_valid <= 1'b0;
            r_sc_res_valid    <= 1'b0;
            cond_valid_r      <= 1'b0;
            r_mem_fault       <= MEM_TRAP_NONE;
            reserve_valid     <= 1'b0;
        end else if (r_mem_fault != MEM_TRAP_NONE) begin
            // Hold the oldest captured memory fault until ID commits the trap.
            r_mem_active          <= 1'b0;
            r_load_data_valid     <= 1'b0;
            r_sc_res_valid        <= 1'b0;
            pipe_buff.instr_valid <= 1'b0;
        end else if (!stall_i) begin
            // When an older memory op faults on the same cycle the pipeline
            // would otherwise advance, the younger EX instruction must be
            // ignored completely.
            if (r_mem_active &&
                (w_page_fault || (!dmem_wait_i && (w_access_fault || pipe_buff.misaligned)))) begin
                pipe_buff         <= MEM_PIPE_BUBBLE;
                r_mem_active      <= 1'b0;
                r_load_data_valid <= 1'b0;
                r_sc_res_valid    <= 1'b0;
                cond_valid_r      <= 1'b0;
                r_mem_fault_pc    <= pipe_buff.pc;
                r_mem_fault_mode  <= pipe_buff.mode;
                if (w_page_fault) begin
                    r_mem_fault    <= store_fault_i ? MEM_TRAP_STORE : MEM_TRAP_LOAD;
                    r_mem_fault_va <= fault_addr_i;
                end else if (w_access_fault) begin
                    r_mem_fault    <= r_mem_store_like ? MEM_TRAP_STORE_ACCESS : MEM_TRAP_LOAD_ACCESS;
                    r_mem_fault_va <= pipe_buff.alu_data;
                end else begin
                    r_mem_fault    <= r_misaligned_access_fault
                                      ? (r_mem_store_like ? MEM_TRAP_STORE_ACCESS : MEM_TRAP_LOAD_ACCESS)
                                      : (r_mem_store_like ? MEM_TRAP_STORE_MISALIGNED : MEM_TRAP_LOAD_MISALIGNED);
                    r_mem_fault_va <= pipe_buff.alu_data;
                end
            end else if (instr_valid_i && w_is_mem_instr && w_mem_misaligned) begin
                // Load/store to misaligned address
                pipe_buff         <= MEM_PIPE_BUBBLE;
                r_mem_active      <= 1'b0;
                r_load_data_valid <= 1'b0;
                r_sc_res_valid    <= 1'b0;
                cond_valid_r      <= 1'b0;
                r_mem_fault       <= w_misaligned_access_fault
                                     ? (w_mem_store_like ? MEM_TRAP_STORE_ACCESS : MEM_TRAP_LOAD_ACCESS)
                                     : (w_mem_store_like ? MEM_TRAP_STORE_MISALIGNED : MEM_TRAP_LOAD_MISALIGNED);
                r_mem_fault_pc    <= pc_i;
                r_mem_fault_va    <= alu_data_i;
                r_mem_fault_mode  <= mode_i;
            end else begin
                // If no faults, capture the new instruction.
                pipe_buff <= '{
                    pc: pc_i,
                    next_pc: next_pc_i,
                    alu_data: alu_data_i,
                    store_data: store_data_i,
                    rd_sel: rd_sel_i,
                    mem_instr_sel: mem_instr_sel_i,
                    load_store_width: load_store_width_i,
                    wb_data_sel: wb_data_sel_i,
                    conditional: conditional_i,
                    clear_reserve: clear_reserve_i,
                    misaligned: w_mem_misaligned,
                    amo_op: amo_op_i,
                    csr_sel: csr_sel_i,
                    csr_readback: csr_readback_i,
                    csr_en: csr_en_i,
                    csr_is_serializing: csr_is_ser_i,
                    instr_valid: instr_valid_i,
                    mode: mode_i
                };
                r_mem_active      <= w_is_mem_instr && (cond_valid || conditional_i);
                r_load_data_valid <= 1'b0;  // Clear on new instruction
                r_sc_res_valid    <= 1'b0;
                cond_valid_r      <= cond_valid;
                r_mem_fault       <= MEM_TRAP_NONE;  // Clear fault on new instruction
            end

            if (!clear_reserve_i && !(instr_valid_i && w_is_mem_instr && w_mem_misaligned)) begin
                if (reserve_i) begin
                    reserve_valid <= 1'b1;
                    reserve_addr  <= alu_data_i;
                end else if (conditional_i && cond_valid) begin
                    // A successful SC.W consumes the active reservation.
                    reserve_valid <= 1'b0;
                end
            end
        end

        else if (r_mem_active && !dmem_wait_i) begin
            r_mem_active <= 1'b0;

            // Capture page fault
            if (w_page_fault) begin
                r_mem_fault      <= store_fault_i ? MEM_TRAP_STORE : MEM_TRAP_LOAD;
                r_mem_fault_pc   <= pipe_buff.pc;
                r_mem_fault_va   <= fault_addr_i;
                r_mem_fault_mode <= pipe_buff.mode;
                pipe_buff.rd_sel <= 5'b0;  // Suppress WB writeback for faulting instruction
                pipe_buff.instr_valid <= 1'b0;
            end else if (w_access_fault) begin
                // Capture access fault
                r_mem_fault    <= r_mem_store_like ? MEM_TRAP_STORE_ACCESS : MEM_TRAP_LOAD_ACCESS;
                r_mem_fault_pc <= pipe_buff.pc;
                r_mem_fault_va <= pipe_buff.alu_data;
                r_mem_fault_mode <= pipe_buff.mode;
                pipe_buff.rd_sel <= 5'b0;
                pipe_buff.instr_valid <= 1'b0;
            end else if (pipe_buff.misaligned) begin
                r_mem_fault    <= r_misaligned_access_fault
                                  ? (r_mem_store_like ? MEM_TRAP_STORE_ACCESS : MEM_TRAP_LOAD_ACCESS)
                                  : (r_mem_store_like ? MEM_TRAP_STORE_MISALIGNED : MEM_TRAP_LOAD_MISALIGNED);
                r_mem_fault_pc <= pipe_buff.pc;
                r_mem_fault_va <= pipe_buff.alu_data;
                r_mem_fault_mode <= pipe_buff.mode;
                pipe_buff.rd_sel <= 5'b0;
                pipe_buff.instr_valid <= 1'b0;
            end

            // Only a SUCCESSFUL SC consumes the reservation.
            // A failing SC is now active only to run the access-permission (PMP/page)
            // check, so it must not clear the reservation.
            if (pipe_buff.conditional && !(w_page_fault || w_access_fault || pipe_buff.misaligned)) begin
                if (cond_valid_r)
                    reserve_valid <= 1'b0;
                r_sc_res <= !cond_valid_r;
                r_sc_res_valid <= 1'b1;
            end

            // Capture load data when load completes
            // Skip on fault
            if (pipe_buff.mem_instr_sel == MEM_INSTR_LOAD &&
                !(w_page_fault || w_access_fault || pipe_buff.misaligned)) begin
                load_data_buff <= load_data;
                r_load_data_valid <= 1'b1;
            end
        end

    end
end

assign dmem_en_o   = r_mem_active;
assign dmem_data_o = pipe_buff.store_data;
assign dmem_wr_o   = r_mem_active && (pipe_buff.mem_instr_sel == MEM_INSTR_STORE) &&
                      (!pipe_buff.conditional || cond_valid_r);
assign dmem_storelike_o = r_mem_active && r_mem_store_like;
assign dmem_amo_op_o    = r_mem_active ? pipe_buff.amo_op : AMO_NONE;

/////////////////////////////////////////////////
// Address and Width Enum Conversion Alignment //
/////////////////////////////////////////////////

always_comb begin
    if (dmem_en_o) begin
        // The downstream memory system expects WIDTH_I8/16/32, so convert U encodings into I.
        unique case (pipe_buff.load_store_width)
            WIDTH_I8, WIDTH_U8:   dmem_size_o = WIDTH_I8;
            WIDTH_I16, WIDTH_U16: dmem_size_o = WIDTH_I16;
            WIDTH_I32:            dmem_size_o = WIDTH_I32;
            default:              dmem_size_o = WIDTH_I32;
        endcase
        // Clear low bits for misaligned accesses, which will trap anyway,
        // but ensures the memory system never sees an unexpected address.
        unique case (pipe_buff.load_store_width)
            WIDTH_I8, WIDTH_U8:   dmem_addr_o = pipe_buff.alu_data;
            WIDTH_I16, WIDTH_U16: dmem_addr_o = {pipe_buff.alu_data[ADDR_WIDTH-1:1], 1'b0};
            WIDTH_I32:            dmem_addr_o = {pipe_buff.alu_data[ADDR_WIDTH-1:2], 2'b00};
            default:              dmem_addr_o = pipe_buff.alu_data;
        endcase
    end else begin
        dmem_size_o = WIDTH_I32;
        dmem_addr_o = '0;
    end
end

/////////////////////////
// Load Data Expansion //
/////////////////////////

// Data will be byte-aligned by how it is stored in memory, so we must shift it to the
// right position based on the original address and the access width.
// ie. for a LH reading 0x1234xxxx from address 0x1002, the data will be stored as 0x00001234 in a register.

always_comb begin
    unique case (pipe_buff.load_store_width)
        WIDTH_I8: unique case (pipe_buff.alu_data[1:0])
            2'b00:   load_data = {{24{dmem_data_i[ 7]}}, dmem_data_i[ 7: 0]};
            2'b01:   load_data = {{24{dmem_data_i[15]}}, dmem_data_i[15: 8]};
            2'b10:   load_data = {{24{dmem_data_i[23]}}, dmem_data_i[23:16]};
            2'b11:   load_data = {{24{dmem_data_i[31]}}, dmem_data_i[31:24]};
            default: load_data = {{24{dmem_data_i[ 7]}}, dmem_data_i[ 7: 0]};
        endcase
        WIDTH_U8: unique case (pipe_buff.alu_data[1:0])
            2'b00:   load_data = {24'h0, dmem_data_i[ 7: 0]};
            2'b01:   load_data = {24'h0, dmem_data_i[15: 8]};
            2'b10:   load_data = {24'h0, dmem_data_i[23:16]};
            2'b11:   load_data = {24'h0, dmem_data_i[31:24]};
            default: load_data = {24'h0, dmem_data_i[ 7: 0]};
        endcase
        WIDTH_I16:
            if (pipe_buff.alu_data[1]) load_data = {{16{dmem_data_i[31]}}, dmem_data_i[31:16]};
            else                       load_data = {{16{dmem_data_i[15]}}, dmem_data_i[15:0]};
        WIDTH_U16:
            if (pipe_buff.alu_data[1]) load_data = {16'h0, dmem_data_i[31:16]};
            else                       load_data = {16'h0, dmem_data_i[15:0]};
        WIDTH_I32: load_data = dmem_data_i;
        default:   load_data = dmem_data_i;
    endcase
end

///////////////////
// Forward to WB //
///////////////////

assign load_data_o = r_load_data_valid ? load_data_buff : load_data;
assign sc_res_o    = {31'h0, r_sc_res_valid ? r_sc_res : !cond_valid_r};

assign rd_sel_o      = w_mem_completion_fault ? 5'b0 : pipe_buff.rd_sel;
assign next_pc_o     = pipe_buff.next_pc;
assign alu_data_o    = pipe_buff.alu_data;
assign wb_data_sel_o = pipe_buff.wb_data_sel;

endmodule

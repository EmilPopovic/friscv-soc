// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

module friscv_decoder
    import friscv_pkg::*;
#(
    parameter bit EnableIsaE = 0,
    parameter bit EnableIsaA = 1,
    parameter bit EnableIsaM = 1
) (
    input  instr_op_t ir_i,
    input  mode_e     mode_i,
    input  logic      dbg_active_i,

    input  logic      tvm_i,
    input  logic      csr_not_implemented_i,
    input  data_t     mcounteren_i,
    input  data_t     scounteren_i,

    input  logic      instr_valid_i,
    output instr_ex_t instr_o,

    output reg_addr_t rs1_sel_o,
    output reg_addr_t rs2_sel_o,
    output reg_addr_t rd_sel_o,
    output imm_e      imm_sel_o,

    output logic      illegal_inst_o,
    output logic      ecall_active_o,
    output logic      ebreak_active_o
);

// When addint C extension, do not decode here
// Add pre-decoder that expands compressed instructions and then feed the expanded instruction here

// satp changes the address translation context globally, so younger
// instructions must wait for the committed update.
function automatic logic is_serializing_csr(csr_addr_e csr_sel);
    logic result;
    result = 1'b0;
    if (csr_sel == CSR_MSTATUS ||
        csr_sel == CSR_SSTATUS ||
        csr_sel == CSR_MEDELEG ||
        csr_sel == CSR_MIDELEG ||
        csr_sel == CSR_SATP) begin
        result = 1'b1;
    end
    return result;
endfunction

function automatic logic is_counter_csr(csr_addr_e csr_sel);
    logic result;
    result = 1'b0;
    if (csr_sel == CSR_CYCLE ||
        csr_sel == CSR_CYCLEH ||
        csr_sel == CSR_TIME ||
        csr_sel == CSR_TIMEH ||
        csr_sel == CSR_INSTRET ||
        csr_sel == CSR_INSTRETH) begin
        result = 1'b1;
    end
    return result;
endfunction

csr_addr_e selected_csr;
assign selected_csr = csr_addr_e'(ir_i.b[31:20]);

// Read-only status and minimum mode of CSR being decoded
logic decode_csr_ro;
assign decode_csr_ro = selected_csr[11:10] == 2'b11;

// For determining if an access is legal, decode_csr_mode stores the minimum mode required
// to access the selected CSR (csr_addr_e selected_csr). Will be garbage if not a CSR instruction.
mode_e decode_csr_mode;
assign decode_csr_mode = mode_e'(selected_csr[9:8]);

// Determine if the instruction being decoded will write to a CSR.
// CSR write will have no effect if either the destination is x0 or uimm is 5'b0.
// This signal is used during CSR instruction to determine if a CSR write is legal
// (i.e. not to a read-only CSR).
logic is_csr_write;
always_comb begin
    unique case (ir_i.r.funct3)
        3'b001, 3'b101: is_csr_write = (ir_i.r.opcode == SYSTEM);  // CSRRW/I always write
        default:        is_csr_write = (ir_i.r.opcode == SYSTEM) && (ir_i.r.rs1 != 5'b0);
    endcase
end

logic       selected_is_ctr;
logic [4:0] selected_ctr_bit;
logic       ctr_access_illegal;

// Determine which counter is selected.
// This will be compared against m/scounteren bits to determine if the access is legal.
always_comb begin
    selected_is_ctr  = 1'b1;
    selected_ctr_bit = 5'd0;
    if (selected_csr == CSR_CYCLE || selected_csr == CSR_CYCLEH)          selected_ctr_bit = 5'd0;
    else if (selected_csr == CSR_TIME || selected_csr == CSR_TIMEH)       selected_ctr_bit = 5'd1;
    else if (selected_csr == CSR_INSTRET || selected_csr == CSR_INSTRETH) selected_ctr_bit = 5'd2;
    else selected_is_ctr = 1'b0;
end

// Determine if current mode can access selected counter.
// Access to a counter is legal if its corresponding m/scounteren bit is set.
always_comb begin
    ctr_access_illegal = 1'b0;
    if (selected_is_ctr) begin
        ctr_access_illegal = mode_i == M_MODE ? 1'b0 :
                             mode_i == S_MODE ?
                              !mcounteren_i[selected_ctr_bit] :
                              !mcounteren_i[selected_ctr_bit] || !scounteren_i[selected_ctr_bit];
    end
end

always_comb begin
    // Set signals to have no side effect by default
    instr_o = NOP_CTRL;
    instr_o.instr_valid = instr_valid_i;
    instr_o.csr_addr = selected_csr;
    instr_o.csr_is_serializing = is_serializing_csr(selected_csr);
    instr_o.csr_is_counter = is_counter_csr(selected_csr);
    rs1_sel_o = 5'b0;
    rs2_sel_o = 5'b0;
    rd_sel_o  = 5'b0;

    imm_sel_o = I_TYPE;

    illegal_inst_o = 1'b0;
    ecall_active_o = 1'b0;
    ebreak_active_o = 1'b0;

    unique case (ir_i.r.opcode)
        LOAD: begin
            instr_o.a_bus_sel = RS1;
            instr_o.b_bus_sel = IMM;
            instr_o.alu_op = ADD_OP;
            instr_o.mem_instr_sel = MEM_INSTR_LOAD;
            instr_o.load_store_width = mem_width_e'(ir_i.r.funct3);
            instr_o.wb_data_sel = WB_DATA_SEL_MEM;

            if (ir_i.r.funct3 == 3'b011 || ir_i.r.funct3 == 3'b110 || ir_i.r.funct3 == 3'b111)
                illegal_inst_o = 1'b1;

            imm_sel_o = I_TYPE;
            rs1_sel_o = ir_i.r.rs1;
            rd_sel_o  = ir_i.r.rd;

            if (EnableIsaE && (ir_i.r.rs1[4] || ir_i.r.rd[4]))
                illegal_inst_o = 1'b1;
        end

        MISC_MEM: begin
            unique case (ir_i.r.funct3)
                // FENCE
                3'b000: begin
                end
                // FENCE.I
                3'b001: begin
                    // BEQ x0, x0, <PC+4> to flush potentially modified fetched instruction
                    instr_o.branch_jal_sel = BRANCH_INSTR;
                    instr_o.branch_cond = COND_EQ;
                    instr_o.a_bus_sel = RS1;    // Branch address = x0 + next_pc
                    instr_o.b_bus_sel = IMM;
                    imm_sel_o = NEXT_PC;
                    instr_o.alu_op = ADD_OP;
                    instr_o.mem_instr_sel = MEM_INSTR_NONE;
                end
                default: illegal_inst_o = 1'b1;
            endcase
        end

        STORE: begin
            instr_o.a_bus_sel = RS1;
            instr_o.b_bus_sel = IMM;
            instr_o.alu_op = ADD_OP;
            instr_o.mem_instr_sel = MEM_INSTR_STORE;
            instr_o.load_store_width = mem_width_e'(ir_i.r.funct3);

            if (ir_i.r.funct3 == 3'b011 || ir_i.r.funct3 >= 3'b100)
                illegal_inst_o = 1'b1;

            imm_sel_o = S_TYPE;
            rs1_sel_o = ir_i.r.rs1;
            rs2_sel_o = ir_i.r.rs2;

            if (EnableIsaE && (ir_i.r.rs1[4] || ir_i.r.rs2[4]))
                illegal_inst_o = 1'b1;
        end

        AMO: begin
            if (EnableIsaA) begin
                unique case (ir_i.r.funct3)
                    3'b010: begin  // RV32A Standard Extension instructions
                        instr_o.wb_data_sel = WB_DATA_SEL_MEM;
                        // This should be treated as a MEM_INSTR_STORE by default,
                        // but I am too lazy to change it.
                        // The MEM stage fixes it by treating all AMOs as amo-like
                        // and all except LR as store-like.
                        instr_o.mem_instr_sel = MEM_INSTR_LOAD;
                        instr_o.load_store_width = WIDTH_I32;
                        instr_o.alu_op = ADD_OP;
                        instr_o.a_bus_sel = RS1;
                        instr_o.b_bus_sel = IMM;
                        imm_sel_o = ZERO;  // AMO has no offset, address = rs1 + 0
                        rd_sel_o  = ir_i.r.rd;
                        rs2_sel_o = ir_i.r.rs2;
                        rs1_sel_o = ir_i.r.rs1;

                        unique case (ir_i.r.funct7[6:2])
                            // SC.W
                            5'b00011: begin
                                instr_o.mem_instr_sel = MEM_INSTR_STORE;
                                instr_o.conditional = 1'b1;
                                instr_o.wb_data_sel = WB_DATA_SEL_SC_RES;
                            end
                            // LR.W
                            5'b00010: begin
                                instr_o.reserve = 1'b1;
                                if (ir_i.r.rs2 != 5'b0) illegal_inst_o = 1'b1;
                            end
                            // AMOSWAP.W
                            5'b00001: instr_o.amo_op = AMO_SWAP;
                            // AMOADD.W
                            5'b00000: instr_o.amo_op = AMO_ADD;
                            // AMOXOR.W
                            5'b00100: instr_o.amo_op = AMO_XOR;
                            // AMOAND.W
                            5'b01100: instr_o.amo_op = AMO_AND;
                            // AMOOR.W
                            5'b01000: instr_o.amo_op = AMO_OR;
                            // AMOMIN.W
                            5'b10000: instr_o.amo_op = AMO_MIN;
                            // AMOMAX.W
                            5'b10100: instr_o.amo_op = AMO_MAX;
                            // AMOMINU.W
                            5'b11000: instr_o.amo_op = AMO_MINU;
                            // AMOMAXU.W
                            5'b11100: instr_o.amo_op = AMO_MAXU;
                            default:  illegal_inst_o = 1'b1;
                        endcase
                    end
                    default: illegal_inst_o = 1'b1;
                endcase

                if (EnableIsaE && (ir_i.r.rs1[4] || ir_i.r.rs2[4] || ir_i.r.rd[4]))
                    illegal_inst_o = 1'b1;
            end else begin
                illegal_inst_o = 1'b1;
            end
        end

        OP: begin  // rd <- rs1 <op> rs2
            // This is an R-type three-operand register-register ALU operation.
            // rs1 and rs2 are the source registers, rd is the destination register.
            instr_o.a_bus_sel = RS1;
            instr_o.b_bus_sel = RS2;
            instr_o.mem_instr_sel = MEM_INSTR_NONE;
            instr_o.wb_data_sel   = WB_DATA_SEL_ALU;

            imm_sel_o = I_TYPE;
            rs1_sel_o = ir_i.r.rs1;
            rs2_sel_o = ir_i.r.rs2;
            rd_sel_o  = ir_i.r.rd;

            unique case (ir_i.r.funct3)
                3'b000:
                    // ADD
                    if      (ir_i.r.funct7 == 7'b0000000) instr_o.alu_op = ADD_OP;
                    // SUB
                    else if (ir_i.r.funct7 == 7'b0100000) instr_o.alu_op = SUB_OP;
                    // MUL
                    else if (ir_i.r.funct7 == 7'b0000001 && EnableIsaM) instr_o.alu_op = MUL_OP;
                    else illegal_inst_o = 1'b1;
                3'b001:
                    // SLL
                    if      (ir_i.r.funct7 == 7'b0000000) instr_o.alu_op = SLL_OP;
                    // MULH
                    else if (ir_i.r.funct7 == 7'b0000001 && EnableIsaM) instr_o.alu_op = MULH_OP;
                    else illegal_inst_o = 1'b1;
                3'b010:
                    // SLT
                    if      (ir_i.r.funct7 == 7'b0000000) instr_o.alu_op = SLT_OP;
                    // MULHSU
                    else if (ir_i.r.funct7 == 7'b0000001 && EnableIsaM) instr_o.alu_op = MULHSU_OP;
                    else illegal_inst_o = 1'b1;
                3'b011:
                    // SLTU
                    if      (ir_i.r.funct7 == 7'b0000000) instr_o.alu_op = SLTU_OP;
                    // MULHU
                    else if (ir_i.r.funct7 == 7'b0000001 && EnableIsaM) instr_o.alu_op = MULHU_OP;
                    else illegal_inst_o = 1'b1;
                3'b100:
                    // XOR
                    if      (ir_i.r.funct7 == 7'b0000000) instr_o.alu_op = XOR_OP;
                    // DIV
                    else if (ir_i.r.funct7 == 7'b0000001 && EnableIsaM) instr_o.alu_op = DIV_OP;
                    else illegal_inst_o = 1'b1;
                3'b101:
                    // SRL
                    if      (ir_i.r.funct7 == 7'b0000000) instr_o.alu_op = SRL_OP;
                    // SRA
                    else if (ir_i.r.funct7 == 7'b0100000) instr_o.alu_op = SRA_OP;
                    // DIVU
                    else if (ir_i.r.funct7 == 7'b0000001 && EnableIsaM) instr_o.alu_op = DIVU_OP;
                    else illegal_inst_o = 1'b1;
                3'b110:
                    // OR
                    if      (ir_i.r.funct7 == 7'b0000000) instr_o.alu_op = OR_OP;
                    // REM
                    else if (ir_i.r.funct7 == 7'b0000001 && EnableIsaM) instr_o.alu_op = REM_OP;
                    else illegal_inst_o = 1'b1;
                3'b111:
                    // AND
                    if      (ir_i.r.funct7 == 7'b0000000) instr_o.alu_op = AND_OP;
                    // REMU
                    else if (ir_i.r.funct7 == 7'b0000001 && EnableIsaM) instr_o.alu_op = REMU_OP;
                    else illegal_inst_o = 1'b1;
                default: illegal_inst_o = 1'b1;
            endcase

            // Check if funct7 of SLL/SLT/SLTU/XOR/OR/AND is legal.
            if ((ir_i.r.funct3 == 3'b001 ||
                 ir_i.r.funct3 == 3'b010 ||
                 ir_i.r.funct3 == 3'b011 ||
                 ir_i.r.funct3 == 3'b100 ||
                 ir_i.r.funct3 == 3'b110 ||
                 ir_i.r.funct3 == 3'b111) &&
                  (ir_i.r.funct7 != 7'b0 && ir_i.r.funct7 != 7'b0000001))
                illegal_inst_o = 1'b1;

            // E instruction set only has x0-x15, uses rd, rs1, rs2
            if (EnableIsaE && (ir_i.r.rs1[4] || ir_i.r.rs2[4] || ir_i.r.rd[4]))
                illegal_inst_o = 1'b1;
        end

        OP_IMM: begin  // rd <- rs1 <op> imm
            // This is an I-type and I2-type ALU operation with an immediate operand.
            // rs1 is the source register, rd is the destination register,
            // and the immediate is the second operand.
            instr_o.a_bus_sel = RS1;
            instr_o.b_bus_sel = IMM;
            instr_o.mem_instr_sel = MEM_INSTR_NONE;
            instr_o.wb_data_sel = WB_DATA_SEL_ALU;

            imm_sel_o = I_TYPE;
            rs1_sel_o = ir_i.r.rs1;
            rd_sel_o  = ir_i.r.rd;
        
            unique case (ir_i.r.funct3)
                // ADDI
                3'b000: instr_o.alu_op = ADD_OP;
                // SLTI
                3'b010: instr_o.alu_op = SLT_OP;
                // SLTIU
                3'b011: instr_o.alu_op = SLTU_OP;
                // XORI
                3'b100: instr_o.alu_op = XOR_OP;
                // ORI
                3'b110: instr_o.alu_op = OR_OP;
                // ANDI
                3'b111: instr_o.alu_op = AND_OP;
                // I2-type shift instructions (with immediate shamt)
                // SLLI
                3'b001: begin
                    imm_sel_o = I2_TYPE;
                    instr_o.alu_op = SLL_OP;
                    if (ir_i.r.funct7 != 7'b0) illegal_inst_o = 1'b1;
                end
                3'b101: begin
                    imm_sel_o = I2_TYPE;
                    unique case (ir_i.r.funct7)
                        // SRLI
                        7'b0000000: instr_o.alu_op = SRL_OP;
                        // SRAI
                        7'b0100000: instr_o.alu_op = SRA_OP;
                        default:    illegal_inst_o = 1'b1;
                    endcase
                end
                default: illegal_inst_o = 1'b1;
            endcase

            // E instruction set only has x0-x15, uses rd, rs1
            if (EnableIsaE && (ir_i.r.rs1[4] || ir_i.r.rd[4]))
                illegal_inst_o = 1'b1;
        end

        AUIPC: begin  // rd <- PC + (imm << 12)
            instr_o.a_bus_sel = PC;
            instr_o.b_bus_sel = IMM;
            instr_o.alu_op = ADD_OP;
            instr_o.mem_instr_sel = MEM_INSTR_NONE;
            instr_o.wb_data_sel = WB_DATA_SEL_ALU;
            imm_sel_o = U_TYPE;
            rd_sel_o  = ir_i.r.rd;

            // Uses rd
            if (EnableIsaE && ir_i.r.rd[4])
                illegal_inst_o = 1'b1;
        end

        LUI: begin  // rd <- imm << 12
            instr_o.a_bus_sel = RS1;
            instr_o.b_bus_sel = IMM;
            instr_o.alu_op = ADD_OP;
            instr_o.mem_instr_sel = MEM_INSTR_NONE;
            instr_o.wb_data_sel = WB_DATA_SEL_ALU;
            imm_sel_o = U_TYPE;
            rd_sel_o  = ir_i.r.rd;

            // Uses rd
            if (EnableIsaE && ir_i.r.rd[4])
                illegal_inst_o = 1'b1;
        end

        BRANCH: begin  // pc <- pc + (imm << 1) if <branch_cond>(rs1, rs2)
            instr_o.branch_jal_sel = BRANCH_INSTR;
            instr_o.a_bus_sel = PC;
            instr_o.b_bus_sel = IMM;
            instr_o.alu_op = ADD_OP;
            instr_o.mem_instr_sel = MEM_INSTR_NONE;

            imm_sel_o = B_TYPE;
            rs1_sel_o = ir_i.r.rs1;
            rs2_sel_o = ir_i.r.rs2;

            unique case (ir_i.r.funct3)
                3'b000:  instr_o.branch_cond = COND_EQ;
                3'b001:  instr_o.branch_cond = COND_NE;
                3'b100:  instr_o.branch_cond = COND_LT;
                3'b101:  instr_o.branch_cond = COND_GE;
                3'b110:  instr_o.branch_cond = COND_LTU;
                3'b111:  instr_o.branch_cond = COND_GEU;
                default: illegal_inst_o = 1'b1;
            endcase

            // Uses rs1, rs2
            if (EnableIsaE && (ir_i.r.rs1[4] || ir_i.r.rs2[4]))
                illegal_inst_o = 1'b1;
        end

        JALR: begin
            instr_o.branch_jal_sel = JAL_INSTR;
            instr_o.jalr_target = 1'b1;
            instr_o.a_bus_sel = RS1;
            instr_o.b_bus_sel = IMM;
            instr_o.alu_op = ADD_OP;
            instr_o.mem_instr_sel = MEM_INSTR_NONE;
            instr_o.wb_data_sel = WB_DATA_SEL_PC_PLUS_4;

            if (ir_i.r.funct3 != 3'b000) illegal_inst_o = 1'b1;

            imm_sel_o = I_TYPE;
            rs1_sel_o = ir_i.r.rs1;
            rd_sel_o  = ir_i.r.rd;

            // Uses rd, rs1
            if (EnableIsaE && (ir_i.r.rs1[4] || ir_i.r.rd[4]))
                illegal_inst_o = 1'b1;
        end

        JAL: begin
            instr_o.branch_jal_sel = JAL_INSTR;
            instr_o.a_bus_sel = PC;
            instr_o.b_bus_sel = IMM;
            instr_o.alu_op = ADD_OP;
            instr_o.mem_instr_sel = MEM_INSTR_NONE;
            instr_o.wb_data_sel = WB_DATA_SEL_PC_PLUS_4;

            imm_sel_o = J_TYPE;
            rd_sel_o  = ir_i.r.rd;

            // Uses rd
            if (EnableIsaE && ir_i.r.rd[4])
                illegal_inst_o = 1'b1;
        end

        SYSTEM: begin
            if (ir_i.r.funct3 == 3'b0) begin  // Non-CSR SYSTEM instructions
                unique case (ir_i.r.funct7)
                    // SFENCE.VMA
                    7'b0001001: begin
                        // SFENCE.VMA requires rd=x0.
                        if      (ir_i.r.rd != 5'b0) illegal_inst_o = 1'b1;
                        // U-mode cannot execute SFENCE.VMA.
                        else if (mode_i == U_MODE)  illegal_inst_o = 1'b1;
                        // S-mode with TVM=1 cannot execute SFENCE.VMA.
                        else if (mode_i == S_MODE && tvm_i) illegal_inst_o = 1'b1;
                        else begin
                            instr_o.sfence_vma = 1'b1;
                            // Flush pipeline and jump to PC+4 to refetch with a clean TLB.
                            instr_o.branch_jal_sel = BRANCH_INSTR;
                            instr_o.branch_cond = COND_ALWAYS;
                            instr_o.a_bus_sel = ZERO_A;
                            instr_o.b_bus_sel = IMM;
                            imm_sel_o = NEXT_PC;
                            instr_o.alu_op = ADD_OP;
                            instr_o.mem_instr_sel = MEM_INSTR_NONE;
                        end
                    end
                    default: begin
                        // These instructions require rs1=x0 and rd=x0.
                        if (ir_i.r.rs1 != 5'b0 || ir_i.r.rd != 5'b0) illegal_inst_o = 1'b1;

                        unique case (ir_i.b[31:20])
                            // ECALL
                            12'b000000000000: ecall_active_o  = 1'b1;
                            // EBREAK
                            12'b000000000001: ebreak_active_o = 1'b1;
                            // MRET
                            12'b001100000010:
                                if (mode_i != M_MODE) illegal_inst_o = 1'b1;
                                else instr_o.mret_en = 1'b1;
                            // SRET
                            12'b000100000010:
                                if (mode_i < S_MODE) illegal_inst_o = 1'b1;
                                else instr_o.sret_en = 1'b1;
                            // DRET
                            12'b011110110010:
                                if (!dbg_active_i) illegal_inst_o = 1'b1;
                            // WFI
                            12'b000100000101: begin
                                // WFI executes as J pc (loops on itself) until an interrupt is
                                // taken where handler breaks from the WFI loop by modifying epc.
                                instr_o.branch_jal_sel = JAL_INSTR;
                                instr_o.a_bus_sel = PC;
                                instr_o.b_bus_sel = IMM;
                                instr_o.alu_op = ADD_OP;
                                imm_sel_o = ZERO;
                            end
                            default: illegal_inst_o = 1'b1;
                        endcase
                    end
                endcase
            end else begin  // CSR read-modify-write instructions
                instr_o.csr_op      = 1'b1;
                instr_o.wb_data_sel = WB_DATA_SEL_CSR;
                rs1_sel_o = ir_i.r.rs1;
                rd_sel_o  = ir_i.r.rd;

                illegal_inst_o = (decode_csr_ro && is_csr_write) ||
                               (mode_i < decode_csr_mode) ||
                               ((mode_i == S_MODE) &&
                                tvm_i &&
                                (selected_csr == CSR_SATP)) ||
                               csr_not_implemented_i ||
                               ctr_access_illegal;

                unique case (ir_i.r.funct3)
                    // CSRRW
                    3'b001: begin
                        instr_o.a_bus_sel = RS1;
                        instr_o.b_bus_sel = IMM;
                        instr_o.alu_op    = OR_OP;
                        imm_sel_o = ZERO;
                    end
                    // CSRRS
                    3'b010: begin
                        instr_o.a_bus_sel = RS1;
                        instr_o.b_bus_sel = CSR;
                        instr_o.alu_op    = OR_OP;
                    end
                    // CSRRC
                    3'b011: begin
                        instr_o.a_bus_sel   = RS1;
                        instr_o.invert_op_a = 1'b1;
                        instr_o.b_bus_sel   = CSR;
                        instr_o.alu_op      = AND_OP;
                    end
                    // CSRRWI
                    3'b101: begin
                        instr_o.a_bus_sel = RS1_SEL;
                        instr_o.b_bus_sel = IMM;
                        instr_o.alu_op    = OR_OP;
                        imm_sel_o = ZERO;
                    end
                    // CSRRSI
                    3'b110: begin
                        instr_o.a_bus_sel = RS1_SEL;
                        instr_o.b_bus_sel = CSR;
                        instr_o.alu_op    = OR_OP;
                    end
                    // CSRRCI
                    3'b111: begin
                        instr_o.a_bus_sel   = RS1_SEL;
                        instr_o.invert_op_a = 1'b1;
                        instr_o.b_bus_sel   = CSR;
                        instr_o.alu_op      = AND_OP;
                    end
                    default: illegal_inst_o = 1'b1;
                endcase

                // Uses rd, rs1
                if (EnableIsaE && (ir_i.r.rs1[4] || ir_i.r.rd[4]))
                    illegal_inst_o = 1'b1;
            end
        end

        // Unsupported major opcodes
        STORE_FP, LOAD_FP,
        CUSTOM_0, CUSTOM_1,
        MADD, MSUB, NMSUB, NMADD,
        OP_FP, OP_V, OP_VE: illegal_inst_o = 1'b1;

        default: illegal_inst_o = 1'b1;
    endcase

    // Propagate illegal instruction as bubble.
    // MUST KEEP THIS LAST, it overrides all other control signals (inserts bubble)
    // if the decoded instruction is illegal.
    if (illegal_inst_o) instr_o = NOP_CTRL;
end

endmodule

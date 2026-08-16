// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

module friscv_decoder import friscv_pkg::*; #(
    parameter bit EnableIsaE = 0,
    parameter bit EnableIsaA = 1,
    parameter bit EnableIsaM = 1
) (
    input  instr_op_t ir_in,
    input  mode_e     mode_in,
    input  logic      dbg_active_in,

    input  logic      tvm_in,
    input  logic      csr_not_implemented_in,
    input  data_t     mcounteren_in,
    input  data_t     scounteren_in,

    input  logic      instr_valid,
    output instr_ex_t instr_ex_out,

    output reg_addr_t rs1_sel_out,
    output reg_addr_t rs2_sel_out,
    output reg_addr_t rd_sel_out,

    output imm_e      imm_sel_out,

    output logic      illegal_inst_out,

    output logic      ecall_active_out,
    output logic      ebreak_active_out
);

// When addint C extension, do not decode here
// Add pre-decoder that expands compressed instructions and then feed the expanded instruction here

// satp changes the address translation context globally, so younger
// instructions must wait for the committed update.
function automatic logic is_serializing_csr(csr_addr_e csr_sel);
    is_serializing_csr = 1'b0;
    if (csr_sel == CSR_MSTATUS ||
        csr_sel == CSR_SSTATUS ||
        csr_sel == CSR_MEDELEG ||
        csr_sel == CSR_MIDELEG ||
        csr_sel == CSR_SATP) begin
        is_serializing_csr = 1'b1;
    end
endfunction

function automatic logic is_counter_csr(csr_addr_e csr_sel);
    is_counter_csr = 1'b0;
    if (csr_sel == CSR_CYCLE ||
        csr_sel == CSR_CYCLEH ||
        csr_sel == CSR_TIME ||
        csr_sel == CSR_TIMEH ||
        csr_sel == CSR_INSTRET ||
        csr_sel == CSR_INSTRETH) begin
        is_counter_csr = 1'b1;
    end
endfunction

csr_addr_e selected_csr;
assign selected_csr = csr_addr_e'(ir_in.b[31:20]);

// Read-only status and minimum mode of CSR being decoded
logic decode_csr_ro;
assign decode_csr_ro = selected_csr[11:10] == 2'b11;

// For determining if an access is legal, decode_csr_mode stores the minimum mode required
// to access the selected CSR (see: csr_addr_e selected_csr). Will be garbage if not a CSR instruction.
mode_e decode_csr_mode;
assign decode_csr_mode = mode_e'(selected_csr[9:8]);

// Determine if the instruction being decoded will write to a CSR.
// CSR write will have no effect if either the destination is x0 or uimm is 5'b0.
// This signal is used during CSR instruction to determine if a CSR write is legal (i.e. not to a read-only CSR).
logic is_csr_write;
always_comb begin
    case (ir_in.r.funct3)
        3'b001, 3'b101: is_csr_write = (ir_in.r.opcode == SYSTEM);  // CSRRW/I always write
        default:        is_csr_write = (ir_in.r.opcode == SYSTEM) && (ir_in.r.rs1 != 5'b0);
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
    if (selected_csr == CSR_CYCLE || selected_csr == CSR_CYCLEH) selected_ctr_bit = 5'd0;
    else if (selected_csr == CSR_TIME || selected_csr == CSR_TIMEH) selected_ctr_bit = 5'd1;
    else if (selected_csr == CSR_INSTRET || selected_csr == CSR_INSTRETH) selected_ctr_bit = 5'd2;
    else selected_is_ctr = 1'b0;
end

// Determine if current mode can access selected counter.
// Access to a counter is legal if its corresponding m/scounteren bit is set.
always_comb begin
    ctr_access_illegal = 1'b0;
    if (selected_is_ctr) begin
        ctr_access_illegal = mode_in == M_MODE ? 1'b0 :
                             mode_in == S_MODE ?
                               !mcounteren_in[selected_ctr_bit] :
                               !mcounteren_in[selected_ctr_bit] || !scounteren_in[selected_ctr_bit];
    end
end

always_comb begin
    // Set signals to have no side effect by default
    instr_ex_out = NOP_CTRL;
    instr_ex_out.instr_valid = instr_valid;
    instr_ex_out.csr_addr = selected_csr;
    instr_ex_out.csr_is_serializing = is_serializing_csr(selected_csr);
    instr_ex_out.csr_is_counter = is_counter_csr(selected_csr);
    rs1_sel_out = 5'b0;
    rs2_sel_out = 5'b0;
    rd_sel_out  = 5'b0;

    imm_sel_out = I_TYPE;

    illegal_inst_out = 1'b0;
    ecall_active_out = 1'b0;
    ebreak_active_out = 1'b0;

    case (ir_in.r.opcode)
        LOAD: begin
            instr_ex_out.a_bus_sel = RS1;
            instr_ex_out.b_bus_sel = IMM;
            instr_ex_out.alu_op = ADD_OP;
            instr_ex_out.mem_instr_sel = MEM_INSTR_LOAD;
            instr_ex_out.load_store_width = mem_width_e'(ir_in.r.funct3);
            instr_ex_out.wb_data_sel = WB_DATA_SEL_MEM;

            if (ir_in.r.funct3 == 3'b011 || ir_in.r.funct3 == 3'b110 || ir_in.r.funct3 == 3'b111)
                illegal_inst_out = 1'b1;

            imm_sel_out = I_TYPE;
            rs1_sel_out = ir_in.r.rs1;
            rd_sel_out  = ir_in.r.rd;

            if (EnableIsaE && (ir_in.r.rs1[4] || ir_in.r.rd[4])) illegal_inst_out = 1'b1;
        end

        MISC_MEM: begin
            case (ir_in.r.funct3)
                3'b000: begin  // FENCE
                end
                3'b001: begin  // FENCE.I
                    // BEQ x0, x0, <PC+4> to flush potentially modified fetched instruction
                    instr_ex_out.branch_jal_sel = BRANCH_INSTR;
                    instr_ex_out.branch_cond = COND_EQ;
                    instr_ex_out.a_bus_sel = RS1;    // Branch address = x0 + next_pc
                    instr_ex_out.b_bus_sel = IMM;
                    imm_sel_out = NEXT_PC;
                    instr_ex_out.alu_op = ADD_OP;
                    instr_ex_out.mem_instr_sel = MEM_INSTR_NONE;
                end
                default: illegal_inst_out = 1'b1;
            endcase
        end

        STORE: begin
            instr_ex_out.a_bus_sel = RS1;
            instr_ex_out.b_bus_sel = IMM;
            instr_ex_out.alu_op = ADD_OP;
            instr_ex_out.mem_instr_sel = MEM_INSTR_STORE;
            instr_ex_out.load_store_width = mem_width_e'(ir_in.r.funct3);

            if (ir_in.r.funct3 == 3'b011 || ir_in.r.funct3 >= 3'b100) illegal_inst_out = 1'b1;

            imm_sel_out = S_TYPE;
            rs1_sel_out = ir_in.r.rs1;
            rs2_sel_out = ir_in.r.rs2;

            if (EnableIsaE && (ir_in.r.rs1[4] || ir_in.r.rs2[4])) illegal_inst_out = 1'b1;
        end

        AMO: begin
            if (EnableIsaA) begin
                case (ir_in.r.funct3)
                    3'b010: begin  // RV32A Standard Extension instructions
                        instr_ex_out.wb_data_sel = WB_DATA_SEL_MEM;
                        // This should be treated as a MEM_INSTR_STORE by default, but I am too lazy to change it.
                        // The MEM stage fixes it by treating all AMOs as amo-like and all except LR as store-like.
                        instr_ex_out.mem_instr_sel = MEM_INSTR_LOAD;
                        instr_ex_out.load_store_width = WIDTH_I32;
                        instr_ex_out.alu_op = ADD_OP;
                        instr_ex_out.a_bus_sel = RS1;
                        instr_ex_out.b_bus_sel = IMM;
                        imm_sel_out = ZERO;  // AMO has no offset, address = rs1 + 0
                        rd_sel_out  = ir_in.r.rd;
                        rs2_sel_out = ir_in.r.rs2;
                        rs1_sel_out = ir_in.r.rs1;

                        case (ir_in.r.funct7[6:2])
                            5'b00011: begin                            // SC.W
                                instr_ex_out.mem_instr_sel = MEM_INSTR_STORE;
                                instr_ex_out.conditional = 1'b1;
                                instr_ex_out.wb_data_sel = WB_DATA_SEL_SC_RES;
                            end
                            5'b00010: begin                            // LR.W
                                instr_ex_out.reserve = 1'b1;
                                if (ir_in.r.rs2 != 5'b0) illegal_inst_out = 1'b1;
                            end
                            5'b00001: instr_ex_out.amo_op = AMO_SWAP;  // AMOSWAP.W
                            5'b00000: instr_ex_out.amo_op = AMO_ADD;   // AMOADD.W
                            5'b00100: instr_ex_out.amo_op = AMO_XOR;   // AMOXOR.W
                            5'b01100: instr_ex_out.amo_op = AMO_AND;   // AMOAND.W
                            5'b01000: instr_ex_out.amo_op = AMO_OR;    // AMOOR.W
                            5'b10000: instr_ex_out.amo_op = AMO_MIN;   // AMOMIN.W
                            5'b10100: instr_ex_out.amo_op = AMO_MAX;   // AMOMAX.W
                            5'b11000: instr_ex_out.amo_op = AMO_MINU;  // AMOMINU.W
                            5'b11100: instr_ex_out.amo_op = AMO_MAXU;  // AMOMAXU.W
                            default:  illegal_inst_out = 1'b1;
                        endcase
                    end
                    default: illegal_inst_out = 1'b1;
                endcase

                if (EnableIsaE && (ir_in.r.rs1[4] || ir_in.r.rs2[4] || ir_in.r.rd[4])) illegal_inst_out = 1'b1;
            end else begin
                illegal_inst_out = 1'b1;
            end
        end

        OP: begin  // rd <- rs1 <op> rs2
            // This is an R-type three-operand register-register ALU operation.
            // rs1 and rs2 are the source registers, rd is the destination register.
            instr_ex_out.a_bus_sel = RS1;
            instr_ex_out.b_bus_sel = RS2;
            instr_ex_out.mem_instr_sel = MEM_INSTR_NONE;
            instr_ex_out.wb_data_sel   = WB_DATA_SEL_ALU;

            imm_sel_out = I_TYPE;
            rs1_sel_out = ir_in.r.rs1;
            rs2_sel_out = ir_in.r.rs2;
            rd_sel_out  = ir_in.r.rd;

            case (ir_in.r.funct3)
                3'b000:
                    if      (ir_in.r.funct7 == 7'b0000000) instr_ex_out.alu_op = ADD_OP;                  // ADD
                    else if (ir_in.r.funct7 == 7'b0100000) instr_ex_out.alu_op = SUB_OP;                  // SUB
                    else if (ir_in.r.funct7 == 7'b0000001 && EnableIsaM) instr_ex_out.alu_op = MUL_OP;    // MUL
                    else illegal_inst_out = 1'b1;
                3'b001:
                    if      (ir_in.r.funct7 == 7'b0000000) instr_ex_out.alu_op = SLL_OP;                  // SLL
                    else if (ir_in.r.funct7 == 7'b0000001 && EnableIsaM) instr_ex_out.alu_op = MULH_OP;   // MULH
                    else illegal_inst_out = 1'b1;
                3'b010:
                    if      (ir_in.r.funct7 == 7'b0000000) instr_ex_out.alu_op = SLT_OP;                  // SLT
                    else if (ir_in.r.funct7 == 7'b0000001 && EnableIsaM) instr_ex_out.alu_op = MULHSU_OP; // MULHSU
                    else illegal_inst_out = 1'b1;
                3'b011:
                    if      (ir_in.r.funct7 == 7'b0000000) instr_ex_out.alu_op = SLTU_OP;                 // SLTU
                    else if (ir_in.r.funct7 == 7'b0000001 && EnableIsaM) instr_ex_out.alu_op = MULHU_OP;  // MULHU
                    else illegal_inst_out = 1'b1;
                3'b100:
                    if      (ir_in.r.funct7 == 7'b0000000) instr_ex_out.alu_op = XOR_OP;                  // XOR
                    else if (ir_in.r.funct7 == 7'b0000001 && EnableIsaM) instr_ex_out.alu_op = DIV_OP;    // DIV
                    else illegal_inst_out = 1'b1;
                3'b101:
                    if      (ir_in.r.funct7 == 7'b0000000) instr_ex_out.alu_op = SRL_OP;                  // SRL
                    else if (ir_in.r.funct7 == 7'b0100000) instr_ex_out.alu_op = SRA_OP;                  // SRA
                    else if (ir_in.r.funct7 == 7'b0000001 && EnableIsaM) instr_ex_out.alu_op = DIVU_OP;   // DIVU
                    else illegal_inst_out = 1'b1;
                3'b110:
                    if      (ir_in.r.funct7 == 7'b0000000) instr_ex_out.alu_op = OR_OP;                   // OR
                    else if (ir_in.r.funct7 == 7'b0000001 && EnableIsaM) instr_ex_out.alu_op = REM_OP;    // REM
                    else illegal_inst_out = 1'b1;
                3'b111:
                    if      (ir_in.r.funct7 == 7'b0000000) instr_ex_out.alu_op = AND_OP;                  // AND
                    else if (ir_in.r.funct7 == 7'b0000001 && EnableIsaM) instr_ex_out.alu_op = REMU_OP;   // REMU
                    else illegal_inst_out = 1'b1;
                default: illegal_inst_out = 1'b1;
            endcase

            // Check if funct7 of SLL/SLT/SLTU/XOR/OR/AND is legal.
            if ((ir_in.r.funct3 == 3'b001 ||
                 ir_in.r.funct3 == 3'b010 ||
                 ir_in.r.funct3 == 3'b011 ||
                 ir_in.r.funct3 == 3'b100 ||
                 ir_in.r.funct3 == 3'b110 ||
                 ir_in.r.funct3 == 3'b111) && (ir_in.r.funct7 != 7'b0 && ir_in.r.funct7 != 7'b0000001))
                illegal_inst_out = 1'b1;
            
            // E instruction set only has x0-x15, uses rd, rs1, rs2
            if (EnableIsaE && (ir_in.r.rs1[4] || ir_in.r.rs2[4] || ir_in.r.rd[4])) illegal_inst_out = 1'b1;
        end

        OP_IMM: begin  // rd <- rs1 <op> imm
            // This is an I-type and I2-type ALU operation with an immediate operand.
            // rs1 is the source register, rd is the destination register, and the immediate is the second operand.
            instr_ex_out.a_bus_sel = RS1;
            instr_ex_out.b_bus_sel = IMM;
            instr_ex_out.mem_instr_sel = MEM_INSTR_NONE;
            instr_ex_out.wb_data_sel = WB_DATA_SEL_ALU;

            imm_sel_out = I_TYPE;
            rs1_sel_out = ir_in.r.rs1;
            rd_sel_out  = ir_in.r.rd;
        
            case (ir_in.r.funct3)
                3'b000: instr_ex_out.alu_op = ADD_OP;       // ADDI
                3'b010: instr_ex_out.alu_op = SLT_OP;       // SLTI
                3'b011: instr_ex_out.alu_op = SLTU_OP;      // SLTIU
                3'b100: instr_ex_out.alu_op = XOR_OP;       // XORI
                3'b110: instr_ex_out.alu_op = OR_OP;        // ORI
                3'b111: instr_ex_out.alu_op = AND_OP;       // ANDI
                // I2-type shift instructions (with immediate shamt)
                3'b001: begin                                     // SLLI
                    imm_sel_out = I2_TYPE;
                    instr_ex_out.alu_op = SLL_OP;
                    if (ir_in.r.funct7 != 7'b0) illegal_inst_out = 1'b1;
                end
                3'b101: begin
                    imm_sel_out = I2_TYPE;
                    case (ir_in.r.funct7)
                        7'b0000000: instr_ex_out.alu_op = SRL_OP;  // SRLI
                        7'b0100000: instr_ex_out.alu_op = SRA_OP;  // SRAI
                        default:    illegal_inst_out = 1'b1;
                    endcase
                end
                default: illegal_inst_out = 1'b1;
            endcase

            // E instruction set only has x0-x15, uses rd, rs1
            if (EnableIsaE && (ir_in.r.rs1[4] || ir_in.r.rd[4])) illegal_inst_out = 1'b1;
        end
        
        AUIPC: begin  // rd <- PC + (imm << 12)
            instr_ex_out.a_bus_sel = PC;
            instr_ex_out.b_bus_sel = IMM;
            instr_ex_out.alu_op = ADD_OP;
            instr_ex_out.mem_instr_sel = MEM_INSTR_NONE;
            instr_ex_out.wb_data_sel = WB_DATA_SEL_ALU;
            imm_sel_out = U_TYPE;
            rd_sel_out  = ir_in.r.rd;

            // Uses rd
            if (EnableIsaE && ir_in.r.rd[4]) illegal_inst_out = 1'b1;
        end
        
        LUI: begin  // rd <- imm << 12
            instr_ex_out.a_bus_sel = RS1;
            instr_ex_out.b_bus_sel = IMM;
            instr_ex_out.alu_op = ADD_OP;
            instr_ex_out.mem_instr_sel = MEM_INSTR_NONE;
            instr_ex_out.wb_data_sel = WB_DATA_SEL_ALU;
            imm_sel_out = U_TYPE;
            rd_sel_out  = ir_in.r.rd;

            // Uses rd
            if (EnableIsaE && ir_in.r.rd[4]) illegal_inst_out = 1'b1;
        end
        
        BRANCH: begin  // pc <- pc + (imm << 1) if <branch_cond>(rs1, rs2)
            instr_ex_out.branch_jal_sel = BRANCH_INSTR;
            instr_ex_out.a_bus_sel = PC;
            instr_ex_out.b_bus_sel = IMM;
            instr_ex_out.alu_op = ADD_OP;
            instr_ex_out.mem_instr_sel = MEM_INSTR_NONE;

            imm_sel_out = B_TYPE;
            rs1_sel_out = ir_in.r.rs1;
            rs2_sel_out = ir_in.r.rs2;

            case (ir_in.r.funct3)
                3'b000:  instr_ex_out.branch_cond = COND_EQ;
                3'b001:  instr_ex_out.branch_cond = COND_NE;
                3'b100:  instr_ex_out.branch_cond = COND_LT;
                3'b101:  instr_ex_out.branch_cond = COND_GE;
                3'b110:  instr_ex_out.branch_cond = COND_LTU;
                3'b111:  instr_ex_out.branch_cond = COND_GEU;
                default: illegal_inst_out = 1'b1;
            endcase

            // Uses rs1, rs2
            if (EnableIsaE && (ir_in.r.rs1[4] || ir_in.r.rs2[4])) illegal_inst_out = 1'b1;
        end
        
        JALR: begin
            instr_ex_out.branch_jal_sel = JAL_INSTR;
            instr_ex_out.jalr_target = 1'b1;
            instr_ex_out.a_bus_sel = RS1;
            instr_ex_out.b_bus_sel = IMM;
            instr_ex_out.alu_op = ADD_OP;
            instr_ex_out.mem_instr_sel = MEM_INSTR_NONE;
            instr_ex_out.wb_data_sel = WB_DATA_SEL_PC_PLUS_4;

            if (ir_in.r.funct3 != 3'b000) illegal_inst_out = 1'b1;

            imm_sel_out = I_TYPE;
            rs1_sel_out = ir_in.r.rs1;
            rd_sel_out  = ir_in.r.rd;

            // Uses rd, rs1
            if (EnableIsaE && (ir_in.r.rs1[4] || ir_in.r.rd[4])) illegal_inst_out = 1'b1;
        end
        
        JAL: begin
            instr_ex_out.branch_jal_sel = JAL_INSTR;
            instr_ex_out.a_bus_sel = PC;
            instr_ex_out.b_bus_sel = IMM;
            instr_ex_out.alu_op = ADD_OP;
            instr_ex_out.mem_instr_sel = MEM_INSTR_NONE;
            instr_ex_out.wb_data_sel = WB_DATA_SEL_PC_PLUS_4;

            imm_sel_out = J_TYPE;
            rd_sel_out  = ir_in.r.rd;

            // Uses rd
            if (EnableIsaE && ir_in.r.rd[4]) illegal_inst_out = 1'b1;
        end
        
        SYSTEM: begin
            if (ir_in.r.funct3 == 3'b0) begin  // Non-CSR SYSTEM instructions
                case (ir_in.r.funct7)
                    7'b0001001: begin  // SFENCE.VMA
                        if      (ir_in.r.rd != 5'b0) illegal_inst_out = 1'b1;           // SFENCE.VMA requires rd=x0.
                        else if (mode_in == U_MODE) illegal_inst_out = 1'b1;            // U-mode cannot execute SFENCE.VMA.
                        else if (mode_in == S_MODE && tvm_in) illegal_inst_out = 1'b1;  // S-mode with TVM=1 cannot execute SFENCE.VMA.
                        else begin
                            instr_ex_out.sfence_vma = 1'b1;
                            // Flush pipeline and jump to PC+4 to refetch with a clean TLB.
                            instr_ex_out.branch_jal_sel = BRANCH_INSTR;
                            instr_ex_out.branch_cond = COND_ALWAYS;
                            instr_ex_out.a_bus_sel = ZERO_A;
                            instr_ex_out.b_bus_sel = IMM;
                            imm_sel_out = NEXT_PC;
                            instr_ex_out.alu_op = ADD_OP;
                            instr_ex_out.mem_instr_sel = MEM_INSTR_NONE;
                        end
                    end
                    default: begin
                        // These instructions require rs1=x0 and rd=x0.
                        if (ir_in.r.rs1 != 5'b0 || ir_in.r.rd != 5'b0) illegal_inst_out = 1'b1;

                        case (ir_in.b[31:20])
                            12'b000000000000: ecall_active_out  = 1'b1;  // ECALL
                            12'b000000000001: ebreak_active_out = 1'b1;  // EBREAK
                            12'b001100000010:        // MRET
                                if (mode_in != M_MODE) illegal_inst_out = 1'b1;
                                else instr_ex_out.mret_en = 1'b1;
                            12'b000100000010:        // SRET
                                if (mode_in < S_MODE) illegal_inst_out = 1'b1;
                                else instr_ex_out.sret_en = 1'b1;
                            12'b011110110010:        // DRET
                                if (!dbg_active_in) illegal_inst_out = 1'b1;
                            12'b000100000101: begin  // WFI
                                // WFI executes as J pc (loops on itself) until an interrupt is taken
                                // where the handler breaks from the WFI loop by modifying epc.
                                instr_ex_out.branch_jal_sel = JAL_INSTR;
                                instr_ex_out.a_bus_sel = PC;
                                instr_ex_out.b_bus_sel = IMM;
                                instr_ex_out.alu_op = ADD_OP;
                                imm_sel_out = ZERO;
                            end
                            default: illegal_inst_out = 1'b1;
                        endcase
                    end
                endcase
            end else begin  // CSR read-modify-write instructions
                instr_ex_out.csr_op      = 1'b1;
                instr_ex_out.wb_data_sel = WB_DATA_SEL_CSR;
                rs1_sel_out = ir_in.r.rs1;
                rd_sel_out  = ir_in.r.rd;

                illegal_inst_out = (decode_csr_ro && is_csr_write) ||
                               (mode_in < decode_csr_mode) ||
                               ((mode_in == S_MODE) &&
                                tvm_in &&
                                (selected_csr == CSR_SATP)) ||
                               csr_not_implemented_in ||
                               ctr_access_illegal;

                case (ir_in.r.funct3)
                    3'b001: begin  //  CSRRW
                        instr_ex_out.a_bus_sel = RS1;
                        instr_ex_out.b_bus_sel = IMM;
                        instr_ex_out.alu_op    = OR_OP;
                        imm_sel_out = ZERO;
                    end
                    3'b010: begin  // CSRRS
                        instr_ex_out.a_bus_sel = RS1;
                        instr_ex_out.b_bus_sel = CSR;
                        instr_ex_out.alu_op    = OR_OP;
                    end
                    3'b011: begin  // CSRRC
                        instr_ex_out.a_bus_sel   = RS1;
                        instr_ex_out.invert_op_a = 1'b1;
                        instr_ex_out.b_bus_sel   = CSR;
                        instr_ex_out.alu_op      = AND_OP;
                    end
                    3'b101: begin  // CSRRWI
                        instr_ex_out.a_bus_sel = RS1_SEL;
                        instr_ex_out.b_bus_sel = IMM;
                        instr_ex_out.alu_op    = OR_OP;
                        imm_sel_out = ZERO;
                    end
                    3'b110: begin  // CSRRSI
                        instr_ex_out.a_bus_sel = RS1_SEL;
                        instr_ex_out.b_bus_sel = CSR;
                        instr_ex_out.alu_op    = OR_OP;
                    end
                    3'b111: begin  // CSRRCI
                        instr_ex_out.a_bus_sel   = RS1_SEL;
                        instr_ex_out.invert_op_a = 1'b1;
                        instr_ex_out.b_bus_sel   = CSR;
                        instr_ex_out.alu_op      = AND_OP;
                    end
                    default: illegal_inst_out = 1'b1;
                endcase

                // Uses rd, rs1
                if (EnableIsaE && (ir_in.r.rs1[4] || ir_in.r.rd[4])) illegal_inst_out = 1'b1;
            end
        end

        // Unsupported major opcodes
        STORE_FP, LOAD_FP,
        CUSTOM_0, CUSTOM_1,
        MADD, MSUB, NMSUB, NMADD,
        OP_FP, OP_V, OP_VE: illegal_inst_out = 1'b1;

        default: illegal_inst_out = 1'b1;
    endcase

    // Propagate illegal instruction as bubble.
    // MUST KEEP THIS LAST, it overrides all other control signals (inserts bubble) if the decoded instruction is illegal.
    if (illegal_inst_out) instr_ex_out = NOP_CTRL;
end

endmodule

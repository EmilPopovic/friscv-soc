// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This module implements the branch unit of the EX stage, which is responsible for
 * evaluating branch conditions and determining whether a branch is taken.
 * It asserts misaligned_out if the target address is not properly aligned, and the redirect should otherwise be taken.
 */

module friscv_branch_unit
    import friscv_pkg::*;
(
    input  jump_sel_e    branch_jal_sel_i,
    input  branch_cond_e branch_cond_i,
    input  data_t        src1_i,
    input  data_t        src2_i,
    input  addr_t        target_i,
    output logic         branch_ok_o,
    output logic         misaligned_o
);

logic [DATA_WIDTH:0] sub;
assign sub = {1'b0, src1_i} + {1'b0, ~src2_i} + 1'b1;

logic  n, z, c, v;
assign n = sub[DATA_WIDTH-1];
assign z = (src1_i == src2_i);
assign c = sub[DATA_WIDTH];
assign v = (src1_i[DATA_WIDTH-1] ^ src2_i[DATA_WIDTH-1]) & (src1_i[DATA_WIDTH-1] ^ sub[DATA_WIDTH-1]);

always_comb begin
    branch_ok_o = 1'b0;
    if (branch_jal_sel_i == BRANCH_INSTR) unique case (branch_cond_i)     
        COND_EQ:     branch_ok_o = z;
        COND_NE:     branch_ok_o = !z;
        COND_LT:     branch_ok_o = n ^ v;
        COND_GE:     branch_ok_o = !(n ^ v);
        COND_LTU:    branch_ok_o = !c;
        COND_GEU:    branch_ok_o = c;
        COND_ALWAYS: branch_ok_o = 1'b1;
        default:     branch_ok_o = 1'b0;
    endcase
end

assign misaligned_o = branch_ok_o && (target_i[1:0] != 2'b0);

endmodule

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

module friscv_branch_unit import friscv_pkg::*; (
    input  jump_sel_e    branch_jal_sel_in,
    input  branch_cond_e branch_cond_in,
    input  data_t        src1_in,
    input  data_t        src2_in,
    input  addr_t        target,
    output logic         branch_ok_out,
    output logic         misaligned_out
);

logic [DATA_WIDTH:0] w_sub;
assign w_sub = {1'b0, src1_in} + {1'b0, ~src2_in} + 1'b1;

logic  n, z, c, v;
assign n = w_sub[DATA_WIDTH-1];
assign z = (src1_in == src2_in);
assign c = w_sub[DATA_WIDTH];
assign v = (src1_in[DATA_WIDTH-1] ^ src2_in[DATA_WIDTH-1]) & (src1_in[DATA_WIDTH-1] ^ w_sub[DATA_WIDTH-1]);

always_comb begin
    branch_ok_out = 1'b0;
    if (branch_jal_sel_in == BRANCH_INSTR) case (branch_cond_in)     
        COND_EQ:     branch_ok_out = z;
        COND_NE:     branch_ok_out = !z;
        COND_LT:     branch_ok_out = n ^ v;
        COND_GE:     branch_ok_out = !(n ^ v);
        COND_LTU:    branch_ok_out = !c;
        COND_GEU:    branch_ok_out = c;
        COND_ALWAYS: branch_ok_out = 1'b1;
        default:     branch_ok_out = 1'b0;
    endcase
end

assign misaligned_out = branch_ok_out && (target[1:0] != 2'b0);

endmodule

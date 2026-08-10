// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * Iterative 32-cycle multiplier and non-restoring divider.
 * i_start begins an operation; o_done pulses when o_result is valid.
 * The result is {high, low} for multiplication or {remainder, quotient}
 * for division. Inputs and outputs must be registered across pipeline stalls.
 */

module friscv_muldiv import friscv_pkg::*, friscv_mem_pkg::*; (
    input  logic        i_clk,
    input  logic        i_rstn,
    input  logic        i_flush,
    input  logic        i_start,
    input  logic        i_mul,
    input  logic        i_a_signed,
    input  logic        i_b_signed,
    input  data_t       i_a,
    input  data_t       i_b,
    output logic [63:0] o_result,
    output logic        o_done
);

    typedef enum logic [1:0] {S_IDLE, S_ACTIVE, S_DONE} state_e;

    state_e      r_state, w_next_state;
    logic [32:0] r_a, w_a;
    data_t       r_m, w_m;
    data_t       r_q, w_q;
    logic [5:0]  r_cnt, w_cnt;
    logic        r_mul, w_mul;
    logic        r_sign, w_sign;
    logic        r_rem_sign, w_rem_sign;
    logic        r_special, w_special;
    logic [63:0] w_result;
    logic        w_done;

    logic        w_a_neg, w_b_neg;
    data_t       w_a_abs, w_b_abs;

    logic [32:0] w_shift_a;
    data_t       w_shift_q;
    logic [32:0] w_alu_a, w_alu_m, w_alu_res;
    logic        w_alu_sub;
    data_t       w_div_q;
    logic [64:0] w_mul_shift;
    logic [63:0] w_prod, w_signed_prod;

    assign w_a_neg = i_a_signed && i_a[31];
    assign w_b_neg = i_b_signed && i_b[31];
    assign w_a_abs = w_a_neg ? (~i_a + 1'b1) : i_a;
    assign w_b_abs = w_b_neg ? (~i_b + 1'b1) : i_b;

    assign w_prod = {r_a[31:0], r_q};
    assign w_signed_prod = r_sign ? (~w_prod + 1'b1) : w_prod;

    // Both algorithms use this single add/subtract path.
    always_comb begin
        {w_shift_a, w_shift_q} = {r_a, r_q} << 1;

        w_alu_a   = r_a;
        w_alu_m   = '0;
        w_alu_sub = 1'b0;

        if (r_state == S_ACTIVE) begin
            if (r_mul) begin
                w_alu_m = r_q[0] ? {1'b0, r_m} : '0;
            end else begin
                w_alu_a   = w_shift_a;
                w_alu_m   = {1'b0, r_m};
                w_alu_sub = !r_a[32];
            end
        end else if (r_state == S_DONE && !r_mul && r_a[32]) begin
            w_alu_m = {1'b0, r_m};
        end

        w_alu_res = w_alu_sub ? w_alu_a - w_alu_m : w_alu_a + w_alu_m;

        w_div_q    = w_shift_q;
        w_div_q[0] = !w_alu_res[32];

        w_mul_shift = {w_alu_res, r_q} >> 1;
    end

    always_comb begin
        w_next_state = r_state;
        w_a          = r_a;
        w_m          = r_m;
        w_q          = r_q;
        w_cnt        = r_cnt;
        w_mul        = r_mul;
        w_sign       = r_sign;
        w_rem_sign   = r_rem_sign;
        w_special    = r_special;
        w_result     = o_result;
        w_done       = o_done;

        if (i_flush) begin
            w_next_state = S_IDLE;
            w_done       = 1'b0;
        end else begin
            case (r_state)
                S_IDLE: begin
                    w_done = 1'b0;

                    if (i_start) begin
                        w_a        = '0;
                        w_m        = w_b_abs;
                        w_q        = w_a_abs;
                        w_cnt      = 6'd32;
                        w_mul      = i_mul;
                        w_sign     = w_a_neg ^ w_b_neg;
                        w_rem_sign = w_a_neg;

                        if (i_mul) begin
                            w_special    = 1'b0;
                            w_next_state = S_ACTIVE;
                        end else if (i_b == '0) begin
                            w_result     = {i_a, 32'hFFFFFFFF};
                            w_special    = 1'b1;
                            w_next_state = S_DONE;
                        end else if (i_a_signed && i_b_signed &&
                                     i_a == 32'h80000000 && i_b == 32'hFFFFFFFF) begin
                            w_result     = {32'b0, 32'h80000000};
                            w_special    = 1'b1;
                            w_next_state = S_DONE;
                        end else begin
                            w_special    = 1'b0;
                            w_next_state = S_ACTIVE;
                        end
                    end
                end

                S_ACTIVE: begin
                    if (r_cnt == 0) begin
                        w_next_state = S_DONE;
                    end else begin
                        if (r_mul) begin
                            w_a = w_mul_shift[64:32];
                            w_q = w_mul_shift[31:0];
                        end else begin
                            w_a = w_alu_res;
                            w_q = w_div_q;
                        end
                        w_cnt = r_cnt - 1'b1;
                    end
                end

                S_DONE: begin
                    if (r_mul) begin
                        w_result = w_signed_prod;
                    end else if (!r_special) begin
                        w_result[31:0]  = r_sign ? (~r_q + 1'b1) : r_q;
                        w_result[63:32] = r_rem_sign
                                        ? (~w_alu_res[31:0] + 1'b1)
                                        : w_alu_res[31:0];
                    end

                    w_done       = 1'b1;
                    w_next_state = S_IDLE;
                end

                default: begin
                    w_next_state = S_IDLE;
                    w_done       = 1'b0;
                end
            endcase
        end
    end

    always_ff @(posedge i_clk) begin
        if (!i_rstn) begin
            r_state    <= S_IDLE;
            r_a        <= '0;
            r_m        <= '0;
            r_q        <= '0;
            r_cnt      <= '0;
            r_mul      <= 1'b0;
            r_sign     <= 1'b0;
            r_rem_sign <= 1'b0;
            r_special  <= 1'b0;
            o_result   <= '0;
            o_done     <= 1'b0;
        end else begin
            r_state    <= w_next_state;
            r_a        <= w_a;
            r_m        <= w_m;
            r_q        <= w_q;
            r_cnt      <= w_cnt;
            r_mul      <= w_mul;
            r_sign     <= w_sign;
            r_rem_sign <= w_rem_sign;
            r_special  <= w_special;
            o_result   <= w_result;
            o_done     <= w_done;
        end
    end

endmodule

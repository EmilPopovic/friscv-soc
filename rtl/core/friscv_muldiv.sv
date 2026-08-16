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

module friscv_muldiv import friscv_pkg::*; (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,
    input  logic        start_i,
    input  logic        mul_i,
    input  logic        a_signed_i,
    input  logic        b_signed_i,
    input  data_t       a_i,
    input  data_t       b_i,
    output logic [63:0] result_o,
    output logic        done_o
);

    typedef enum logic [1:0] {StIdle, StActive, StDone} state_e;

    state_e      state_q, state_d;
    logic [32:0] a_q, a_d;
    data_t       m_q, m_d;
    data_t       q_q, q_d;
    logic [5:0]  cnt_q, cnt_d;
    logic        mul_q, mul_d;
    logic        sign_q, sign_d;
    logic        rem_sign_q, rem_sign_d;
    logic        special_q, special_d;
    logic [63:0] result;
    logic        done;

    logic        a_neg, b_neg;
    data_t       a_abs, b_abs;

    logic [32:0] shift_a;
    data_t       shift_q;
    logic [32:0] alu_a, alu_m, alu_res;
    logic        alu_sub;
    data_t       div_q;
    logic [64:0] mul_shift;
    logic [63:0] prod, signed_prod;

    assign a_neg = a_signed_i && a_i[31];
    assign b_neg = b_signed_i && b_i[31];
    assign a_abs = a_neg ? (~a_i + 1'b1) : a_i;
    assign b_abs = b_neg ? (~b_i + 1'b1) : b_i;

    assign prod = {a_q[31:0], q_q};
    assign signed_prod = sign_q ? (~prod + 1'b1) : prod;

    // Both algorithms use this single add/subtract path.
    always_comb begin
        {shift_a, shift_q} = {a_q, q_q} << 1;

        alu_a   = a_q;
        alu_m   = '0;
        alu_sub = 1'b0;

        if (state_q == StActive) begin
            if (mul_q) begin
                alu_m = q_q[0] ? {1'b0, m_q} : '0;
            end else begin
                alu_a   = shift_a;
                alu_m   = {1'b0, m_q};
                alu_sub = !a_q[32];
            end
        end else if (state_q == StDone && !mul_q && a_q[32]) begin
            alu_m = {1'b0, m_q};
        end

        alu_res = alu_sub ? alu_a - alu_m : alu_a + alu_m;

        div_q    = shift_q;
        div_q[0] = !alu_res[32];

        mul_shift = {alu_res, q_q} >> 1;
    end

    always_comb begin
        state_d    = state_q;
        a_d        = a_q;
        m_d        = m_q;
        q_d        = q_q;
        cnt_d      = cnt_q;
        mul_d      = mul_q;
        sign_d     = sign_q;
        rem_sign_d = rem_sign_q;
        special_d  = special_q;
        result     = result_o;
        done       = done_o;

        if (flush_i) begin
            state_d = StIdle;
            done    = 1'b0;
        end else begin
            case (state_q)
                StIdle: begin
                    done = 1'b0;

                    if (start_i) begin
                        a_d        = '0;
                        m_d        = b_abs;
                        q_d        = a_abs;
                        cnt_d      = 6'd32;
                        mul_d      = mul_i;
                        sign_d     = a_neg ^ b_neg;
                        rem_sign_d = a_neg;

                        if (mul_i) begin
                            special_d = 1'b0;
                            state_d   = StActive;
                        end else if (b_i == '0) begin
                            result    = {a_i, 32'hFFFFFFFF};
                            special_d = 1'b1;
                            state_d   = StDone;
                        end else if (a_signed_i && b_signed_i && a_i == 32'h80000000 && b_i == 32'hFFFFFFFF) begin
                            result    = {32'b0, 32'h80000000};
                            special_d = 1'b1;
                            state_d   = StDone;
                        end else begin
                            special_d    = 1'b0;
                            state_d   = StActive;
                        end
                    end
                end

                StActive: begin
                    if (cnt_q == 0) begin
                        state_d = StDone;
                    end else begin
                        if (mul_q) begin
                            a_d = mul_shift[64:32];
                            q_d = mul_shift[31:0];
                        end else begin
                            a_d = alu_res;
                            q_d = div_q;
                        end
                        cnt_d = cnt_q - 1'b1;
                    end
                end

                StDone: begin
                    if (mul_q) begin
                        result = signed_prod;
                    end else if (!special_q) begin
                        result[31:0]  = sign_q ? (~q_q + 1'b1) : q_q;
                        result[63:32] = rem_sign_q ? (~alu_res[31:0] + 1'b1) : alu_res[31:0];
                    end

                    done    = 1'b1;
                    state_d = StIdle;
                end

                default: begin
                    done    = 1'b0;
                    state_d = StIdle;
                end
            endcase
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q    <= StIdle;
            a_q        <= '0;
            m_q        <= '0;
            q_q        <= '0;
            cnt_q      <= '0;
            mul_q      <= 1'b0;
            sign_q     <= 1'b0;
            rem_sign_q <= 1'b0;
            special_q  <= 1'b0;
            result_o   <= '0;
            done_o     <= 1'b0;
        end else begin
            state_q    <= state_d;
            a_q        <= a_d;
            m_q        <= m_d;
            q_q        <= q_d;
            cnt_q      <= cnt_d;
            mul_q      <= mul_d;
            sign_q     <= sign_d;
            rem_sign_q <= rem_sign_d;
            special_q  <= special_d;
            result_o   <= result;
            done_o     <= done;
        end
    end

endmodule

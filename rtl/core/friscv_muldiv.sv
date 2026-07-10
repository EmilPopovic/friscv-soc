// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
//
// Version info is listed in friscv_pkg.sv

/*
 * This module implements non-pipelined iterative multiplication and the
 * non-restoring division algorithm. Multiplication uses the same A/M/Q
 * registers and add/subtract datapath.
 * It supports signed and unsigned multiplication and division, as well as
 * division by zero and the overflow case of INT_MIN / -1.
 * The operation is started when start_in is asserted and the operands are
 * stable. Normal operations take 32 iterations.
 * When the operation is complete, done_out is asserted for one cycle.
 *
 * result_out is {product_high, product_low} after multiplication and
 * {remainder, quotient} after division.
 *
 * Note: always register the inputs and outputs of this module to avoid bugs
 * during pipeline stalls.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

module friscv_muldiv (
    input  logic        clk_in,
    input  logic        rst_n_in,
    input  logic        flush_in,
    input  logic        start_in,
    input  logic        multiply_in,
    input  logic        operand_a_signed_in,
    input  logic        operand_b_signed_in,
    input  data_t       operand_a_in,
    input  data_t       operand_b_in,
    output logic [63:0] result_out,
    output logic        done_out
);

    typedef enum logic [1:0] {IDLE, ACTIVE, DONE} state_e;

    state_e      current_state, next_state;
    logic [32:0] A, next_A;
    data_t       M, next_M;
    data_t       Q, next_Q;
    logic [5:0]  counter, next_counter;
    logic        multiply, next_multiply;
    logic        result_sign, next_result_sign;
    logic        remainder_sign, next_remainder_sign;
    logic        edge_case, next_edge_case;
    logic [63:0] next_result;
    logic        next_done;

    logic        operand_a_negative, operand_b_negative;
    data_t       operand_a_magnitude, operand_b_magnitude;

    logic [32:0] shifted_A;
    data_t       shifted_Q;
    logic [32:0] arithmetic_A, arithmetic_M, arithmetic_result;
    logic        arithmetic_subtract;
    data_t       division_Q;
    logic [64:0] multiplication_shift;
    logic [63:0] unsigned_product, signed_product;

    assign operand_a_negative = operand_a_signed_in && operand_a_in[31];
    assign operand_b_negative = operand_b_signed_in && operand_b_in[31];
    assign operand_a_magnitude = operand_a_negative ? (~operand_a_in + 1'b1) : operand_a_in;
    assign operand_b_magnitude = operand_b_negative ? (~operand_b_in + 1'b1) : operand_b_in;

    assign unsigned_product = {A[31:0], Q};
    assign signed_product = result_sign ? (~unsigned_product + 1'b1) : unsigned_product;

    // Both algorithms use this single add/subtract path.
    always_comb begin
        {shifted_A, shifted_Q} = {A, Q} << 1;

        arithmetic_A        = A;
        arithmetic_M        = '0;
        arithmetic_subtract = 1'b0;

        if (current_state == ACTIVE) begin
            if (multiply) begin
                arithmetic_M = Q[0] ? {1'b0, M} : '0;
            end else begin
                arithmetic_A        = shifted_A;
                arithmetic_M        = {1'b0, M};
                arithmetic_subtract = !A[32];
            end
        end else if (current_state == DONE && !multiply && A[32]) begin
            arithmetic_M = {1'b0, M};
        end

        arithmetic_result = arithmetic_subtract
                          ? arithmetic_A - arithmetic_M
                          : arithmetic_A + arithmetic_M;

        division_Q    = shifted_Q;
        division_Q[0] = !arithmetic_result[32];

        multiplication_shift = {arithmetic_result, Q} >> 1;
    end

    always_comb begin
        next_state          = current_state;
        next_A              = A;
        next_M              = M;
        next_Q              = Q;
        next_counter        = counter;
        next_multiply       = multiply;
        next_result_sign    = result_sign;
        next_remainder_sign = remainder_sign;
        next_edge_case      = edge_case;
        next_result         = result_out;
        next_done           = done_out;

        if (flush_in) begin
            next_state = IDLE;
            next_done  = 1'b0;
        end else begin
            case (current_state)
                IDLE: begin
                    next_done = 1'b0;

                    if (start_in) begin
                        next_A              = '0;
                        next_M              = operand_b_magnitude;
                        next_Q              = operand_a_magnitude;
                        next_counter        = 6'd32;
                        next_multiply       = multiply_in;
                        next_result_sign    = operand_a_negative ^ operand_b_negative;
                        next_remainder_sign = operand_a_negative;

                        if (multiply_in) begin
                            next_edge_case = 1'b0;
                            next_state     = ACTIVE;
                        end else if (operand_b_in == '0) begin
                            next_result    = {operand_a_in, 32'hFFFFFFFF};
                            next_edge_case = 1'b1;
                            next_state     = DONE;
                        end else if (operand_a_signed_in && operand_b_signed_in &&
                                     operand_a_in == 32'h80000000 && operand_b_in == 32'hFFFFFFFF) begin
                            next_result    = {32'b0, 32'h80000000};
                            next_edge_case = 1'b1;
                            next_state     = DONE;
                        end else begin
                            next_edge_case = 1'b0;
                            next_state     = ACTIVE;
                        end
                    end
                end

                ACTIVE: begin
                    if (counter == 0) begin
                        next_state = DONE;
                    end else begin
                        if (multiply) begin
                            next_A = multiplication_shift[64:32];
                            next_Q = multiplication_shift[31:0];
                        end else begin
                            next_A = arithmetic_result;
                            next_Q = division_Q;
                        end
                        next_counter = counter - 1'b1;
                    end
                end

                DONE: begin
                    if (multiply) begin
                        next_result = signed_product;
                    end else if (!edge_case) begin
                        next_result[31:0]  = result_sign ? (~Q + 1'b1) : Q;
                        next_result[63:32] = remainder_sign
                                           ? (~arithmetic_result[31:0] + 1'b1)
                                           : arithmetic_result[31:0];
                    end

                    next_done  = 1'b1;
                    next_state = IDLE;
                end

                default: begin
                    next_state = IDLE;
                    next_done  = 1'b0;
                end
            endcase
        end
    end

    always_ff @(posedge clk_in) begin
        if (!rst_n_in) begin
            current_state  <= IDLE;
            A              <= '0;
            M              <= '0;
            Q              <= '0;
            counter        <= '0;
            multiply       <= 1'b0;
            result_sign    <= 1'b0;
            remainder_sign <= 1'b0;
            edge_case      <= 1'b0;
            result_out     <= '0;
            done_out       <= 1'b0;
        end else begin
            current_state  <= next_state;
            A              <= next_A;
            M              <= next_M;
            Q              <= next_Q;
            counter        <= next_counter;
            multiply       <= next_multiply;
            result_sign    <= next_result_sign;
            remainder_sign <= next_remainder_sign;
            edge_case      <= next_edge_case;
            result_out     <= next_result;
            done_out       <= next_done;
        end
    end

endmodule

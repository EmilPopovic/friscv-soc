// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

`timescale 1ns/1ps

import friscv_pkg::*;

module friscv_hb_guard (
    input  logic         i_hb_en,
    friscv_mem_if.slave  s_if,
    friscv_mem_if.master m_if
);

always_comb begin
    // Request path
    m_if.addr     = s_if.addr;
    m_if.size     = s_if.size;
    m_if.wdata    = s_if.wdata;
    m_if.burst_en = s_if.burst_en;
    m_if.rw       = i_hb_en ? s_if.rw : RW_IDLE;

    // Response path
    if (i_hb_en) begin
        s_if.rdata      = m_if.rdata;
        s_if.wait_req   = m_if.wait_req;
        s_if.beat_valid = m_if.beat_valid;
        s_if.err        = m_if.err;
    end else begin
        s_if.rdata      = '0;
        s_if.wait_req   = 1'b0;
        s_if.beat_valid = 1'b0;
        s_if.err        = (s_if.rw != RW_IDLE);
    end
end

endmodule

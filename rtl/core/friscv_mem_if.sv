// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This interface defines the signals for the external memory interface of the FRISC-V CPU subsystem.
 * It should be used on the core-side of any adapter implementation.
 *
 * See docs/MEM_IF.md for details on the protocol.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

interface friscv_mem_if;

    mem_width_e size;
    addr_t      addr;
    data_t      wdata;
    data_t      rdata;
    rw_cmd_e    rw;
    logic       wait_req;
    logic       burst_en;
    logic       beat_valid;
    logic       err;

    modport master (
        output size, addr, wdata, rw, burst_en,
        input  rdata, wait_req, beat_valid, err
    );

    modport slave (
        input  size, addr, wdata, rw, burst_en,
        output rdata, wait_req, beat_valid, err
    );

endinterface

// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

/*
 * This file defines the interface between the FRISC-V core and downstream memory components.
 * It is used for buffering requests between the core/MMU and the AMO unit and external bus.
 */

`timescale 1ns / 1ps

import friscv_pkg::*;

interface friscv_l2_if;
    logic       valid;
    logic       stall;
    logic       err;
    addr_t      addr;
    mem_width_e size;
    data_t      wdata;
    data_t      rdata;
    rw_cmd_e    rw;
    amo_op_e    amo_op;

    modport requester (
        output valid, addr, size, wdata, rw, amo_op,
        input  stall, err, rdata
    );

    modport responder (
        input  valid, addr, size, wdata, rw, amo_op,
        output stall, err, rdata
    );
endinterface

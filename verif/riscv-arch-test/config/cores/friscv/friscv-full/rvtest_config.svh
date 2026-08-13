// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
//
// Emil Popović <mail@emilpopovic.me>

`define XLEN32

`define G 0
`define G_IS_0
`define RVMODEL_ACCESS_FAULT_ADDRESS 32'h00000000
`define CLINT_BASE 32'h02000000

`define S_SUPPORTED
`define SV32_SUPPORTED
`define ZAAMO_SUPPORTED
`define ZALRSC_SUPPORTED
`define COUNTINHIBIT_EN_0
`define COUNTINHIBIT_EN_2
`define TIME_CSR_IMPLEMENTED

// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
//
// Emil Popović <mail@emilpopovic.me>

`include "axi/typedef.svh"
`include "register_interface/typedef.svh"
`include "apb/typedef.svh"

package vernii_pkg;

localparam int unsigned AddrWidth    = 32;
localparam int unsigned DataWidth    = 32;
localparam int unsigned StrbWidth    = DataWidth / 8;
localparam int unsigned AxiIdWidth   = 1;
localparam int unsigned AxiUserWidth = 1;

typedef logic [AddrWidth-1:0]    addr_t;
typedef logic [DataWidth-1:0]    data_t;
typedef logic [StrbWidth-1:0]    strb_t;
typedef logic [AxiIdWidth-1:0]   id_t;
typedef logic [AxiUserWidth-1:0] user_t;

`AXI_LITE_TYPEDEF_ALL(vernii_axi_lite, addr_t, data_t, strb_t)
`AXI_TYPEDEF_ALL(vernii_axi, addr_t, id_t, data_t, strb_t, user_t)
`REG_BUS_TYPEDEF_ALL(vernii_reg, addr_t, data_t, strb_t)
`APB_TYPEDEF_ALL(vernii_apb, addr_t, data_t, strb_t)

localparam int unsigned NumIntRegPorts = 9;

endpackage

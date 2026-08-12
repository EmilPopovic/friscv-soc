// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

// Generated from zsbl.S by gen_zsbl_rom.py, do not edit
package friscv_zsbl_rom_pkg;

    import friscv_pkg::*;

    localparam int unsigned ZSBL_PROG_WORDS = 31;
    localparam int unsigned ZSBL_PROG_BYTES = ZSBL_PROG_WORDS * 4;
    localparam inst_t ZSBL_PROG [31] = '{
        32'h400002b7,
        32'h0042a303,
        32'h00137313,
        32'h00031e63,
        32'h00100313,
        32'h0062a023,
        32'h0002a383,
        32'hfe638ee3,
        32'h0000100f,
        32'h00038067,
        32'h600002b7,
        32'ha0000337,
        32'h0062a823,
        32'h00300313,
        32'h0262a823,
        32'h00002337,
        32'h20330313,
        32'h0262a423,
        32'h00001337,
        32'h1ff30313,
        32'h0262a423,
        32'he0000513,
        32'h0142a383,
        32'h00739393,
        32'hfe03cce3,
        32'h02c2a383,
        32'h20752023,
        32'h00450513,
        32'hfe0514e3,
        32'h0000100f,
        32'h00000067
    };

endpackage : friscv_zsbl_rom_pkg

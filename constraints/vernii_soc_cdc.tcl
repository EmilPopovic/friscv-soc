# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Licensed under the Solderpad Hardware License v 2.1 (the "License");
# you may not use this file except in compliance with the License, or,
# at your option, the Apache License version 2.0.
# You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/
#
# Emil Popović <mail@emilpopovic.me>

proc vernii_soc_cdc_constraints {core_clk tck} {
    set core_period [get_property PERIOD [lindex $core_clk 0]]
    set tck_period  [get_property PERIOD [lindex $tck 0]]
    set budget      [expr {min($core_period, $tck_period)}]

    set_max_delay -datapath_only $budget -from $tck      -to $core_clk
    set_max_delay -datapath_only $budget -from $core_clk -to $tck

    set_property ASYNC_REG true \
        [get_cells -hier -filter {NAME =~ *i_rstgen_tck/*synch_regs_q*}]

    puts "vernii_soc: TCK/core crossing declared, ${budget} ns datapath budget"
}

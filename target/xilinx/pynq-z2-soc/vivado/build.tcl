set here   [file dirname [file normalize [info script]]]
set target [file dirname $here]
set root   [file dirname [file dirname [file dirname $target]]]
set outdir $::env(OUTDIR)
set top    $::env(TOP)
set part   $::env(PART)
set board  $::env(BOARD)

file mkdir $outdir/reports

# Split the bender flist into include dirs, defines and sources
set incdirs {}
set defines {}
set files   {}
set fh [open $::env(FLIST)]
foreach line [split [read $fh] "\n"] {
    set line [string trim $line]
    if {$line eq ""} continue
    if {[string match "+incdir+*" $line]} {
        lappend incdirs [string range $line 8 end]
    } elseif {[string match "+define+*" $line]} {
        lappend defines -verilog_define [string range $line 8 end]
    } else {
        lappend files $line
    }
}
close $fh

set headers {}
foreach d $incdirs {
    foreach h [glob -nocomplain -directory $d */*.svh *.svh] {
        lappend headers $h
    }
}

create_project -in_memory -part $part
set_property board_part $board [current_project]
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
set_property include_dirs $incdirs [current_fileset]
set_property source_mgmt_mode All [current_project]
foreach d $defines {
    if {$d ne "-verilog_define"} {
        set_property verilog_define \
            [concat [get_property verilog_define [current_fileset]] $d] \
            [current_fileset]
    }
}

read_verilog -sv $files
if {[llength $headers]} {
    read_verilog -sv $headers
    set_property file_type {Verilog Header} [get_files $headers]
    set_property is_global_include true [get_files $headers]
}
read_verilog $target/src/${top}_wrap.v

source $root/constraints/vernii_soc_cdc.tcl
read_xdc -unmanaged $target/constraints/vernii_soc_pynq_ps.xdc

create_bd_design bd
update_compile_order -fileset sources_1

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" \
             Master "Disable" Slave "Disable"} [get_bd_cells ps7]
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {32} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $::env(SOC_FREQ_MHZ) \
] [get_bd_cells ps7]

create_bd_cell -type module -reference ${top}_wrap soc
set_property -dict [list \
    CONFIG.SramBase $::env(SRAM_BASE) \
    CONFIG.SramSize $::env(SRAM_SIZE) \
    CONFIG.MemBase $::env(MEM_BASE) \
    CONFIG.MemSize $::env(MEM_SIZE) \
    CONFIG.MemPsBase $::env(MEM_PS_BASE) \
    CONFIG.ZsblRom $::env(ZSBL) \
] [get_bd_cells soc]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells sc]

connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins soc/clk_i] [get_bd_pins sc/aclk] [get_bd_pins ps7/S_AXI_HP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins soc/rstn_i] [get_bd_pins sc/aresetn]

connect_bd_intf_net [get_bd_intf_pins soc/m_axi] [get_bd_intf_pins sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]

foreach p {led_o jtag_tck_i jtag_tms_i jtag_tdi_i jtag_tdo_o uart_rx_i uart_tx_o
           qspi_sck_o qspi_cs_o qspi_sd_io gpio_io} {
    make_bd_pins_external -name $p [get_bd_pins soc/$p]
}

assign_bd_address
validate_bd_design
save_bd_design

set bd_file [get_files bd.bd]
set_property synth_checkpoint_mode None $bd_file
generate_target all $bd_file
make_wrapper -files $bd_file -top -import

set_property source_mgmt_mode None [current_project]

synth_design -top bd_wrapper -part $part

write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/reports/synth_util.rpt
if {$::env(STAGE) eq "synth"} { exit 0 }

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force $outdir/post_route.dcp
report_utilization    -file $outdir/reports/util.rpt
report_timing_summary -report_unconstrained -file $outdir/reports/timing.rpt
report_drc            -file $outdir/reports/drc.rpt

check_timing -file $outdir/reports/check_timing.rpt
report_cdc -details  -file $outdir/reports/cdc.rpt

set cdc_crit "n/a"
catch { set cdc_crit [llength [get_cdc_violations -quiet -severity Critical]] }

set unconstrained_pins "n/a"
if {![catch {set fh [open $outdir/reports/check_timing.rpt]}]} {
    set txt [read $fh]
    close $fh
    if {[regexp {There are (\d+) pins that are not constrained for maximum delay} $txt -> n]} {
        set unconstrained_pins $n
    }
}

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
set met [expr {$wns >= 0 && $whs >= 0}]

set fh [open $outdir/reports/summary.txt w]
puts $fh "part $part  board $board  freq $::env(SOC_FREQ_MHZ) MHz  zsbl $::env(ZSBL)"
puts $fh "WNS $wns  WHS $whs  [expr {$met ? {MET} : {VIOLATED}}]"
puts $fh "unconstrained max-delay pins $unconstrained_pins  critical CDC violations $cdc_crit"
close $fh

if {$unconstrained_pins ne "n/a" && $unconstrained_pins > 0} {
    send_msg_id {VERNII 1-2} CRITICAL_WARNING "$unconstrained_pins pins have no maximum delay constraint, the WNS below does not cover them. See reports/check_timing.rpt."
}
if {$cdc_crit ne "n/a" && $cdc_crit > 0} {
    send_msg_id {VERNII 1-3} CRITICAL_WARNING "$cdc_crit critical CDC violations. See reports/cdc.rpt."
}

if {$::env(STAGE) eq "bitstream"} { write_bitstream -force $outdir/$top.bit }

puts "WNS $wns  WHS $whs  [expr {$met ? {TIMING MET} : {TIMING VIOLATED}}]"
if {!$met} { exit 1 }

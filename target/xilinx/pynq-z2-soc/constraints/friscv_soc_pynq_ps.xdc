# Design constraints for friscv_soc_pynq_ps.

set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports {led_o[0]}]
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports {led_o[1]}]
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports {led_o[2]}]
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports {led_o[3]}]

# TCK drives a BUFGMUX, so it needs the P side of a clock-capable pin: a plain
# pin fails Place 30-574, the N side fails DRC PLIO-9. U7, Y9, Y7 are P-side.
set_property -dict { PACKAGE_PIN C20 IOSTANDARD LVCMOS33 PULLUP   true } [get_ports jtag_tdi_i]
set_property -dict { PACKAGE_PIN W6  IOSTANDARD LVCMOS33 PULLUP   true } [get_ports jtag_tms_i]
set_property -dict { PACKAGE_PIN Y7  IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports jtag_tck_i]
set_property -dict { PACKAGE_PIN F20 IOSTANDARD LVCMOS33                } [get_ports jtag_tdo_o]
set_property -dict { PACKAGE_PIN V6  IOSTANDARD LVCMOS33                } [get_ports uart_tx_o]
set_property -dict { PACKAGE_PIN Y6  IOSTANDARD LVCMOS33 PULLUP   true } [get_ports uart_rx_i]

# QSPI0 on PMODA
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports {qspi_sd_io[0]}] ;# JA2
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports {qspi_sd_io[1]}] ;# JA3
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports {qspi_sd_io[2]}] ;# JA7
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {qspi_sd_io[3]}] ;# JA8
set_property -dict { PACKAGE_PIN Y17 IOSTANDARD LVCMOS33 } [get_ports qspi_sck_o]      ;# JA4
set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports {qspi_cs_o[0]}]  ;# JA1
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports {qspi_cs_o[1]}]  ;# JA9
set_property -dict { PACKAGE_PIN W19 IOSTANDARD LVCMOS33 } [get_ports {qspi_cs_o[2]}]  ;# JA10

# GPIO on PMODB
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports {gpio_io[0]}]  ;# JB1
set_property -dict { PACKAGE_PIN Y14 IOSTANDARD LVCMOS33 } [get_ports {gpio_io[1]}]  ;# JB2
set_property -dict { PACKAGE_PIN T11 IOSTANDARD LVCMOS33 } [get_ports {gpio_io[2]}]  ;# JB3
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports {gpio_io[3]}]  ;# JB4
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {gpio_io[4]}]  ;# JB7

# GPIO on the Raspberry Pi header
set_property -dict { PACKAGE_PIN F19 IOSTANDARD LVCMOS33 } [get_ports {gpio_io[5]}]  ;# GPIO8,  pin 24
set_property -dict { PACKAGE_PIN V10 IOSTANDARD LVCMOS33 } [get_ports {gpio_io[6]}]  ;# GPIO9,  pin 21
set_property -dict { PACKAGE_PIN V8  IOSTANDARD LVCMOS33 } [get_ports {gpio_io[7]}]  ;# GPIO10, pin 19
set_property -dict { PACKAGE_PIN W10 IOSTANDARD LVCMOS33 } [get_ports {gpio_io[8]}]  ;# GPIO11, pin 23
set_property -dict { PACKAGE_PIN B20 IOSTANDARD LVCMOS33 } [get_ports {gpio_io[9]}]  ;# GPIO12, pin 32
set_property -dict { PACKAGE_PIN W8  IOSTANDARD LVCMOS33 } [get_ports {gpio_io[10]}] ;# GPIO13, pin 33
set_property -dict { PACKAGE_PIN B19 IOSTANDARD LVCMOS33 } [get_ports {gpio_io[11]}] ;# GPIO16, pin 36
set_property -dict { PACKAGE_PIN Y8  IOSTANDARD LVCMOS33 } [get_ports {gpio_io[12]}] ;# GPIO19, pin 35
set_property -dict { PACKAGE_PIN Y9  IOSTANDARD LVCMOS33 } [get_ports {gpio_io[13]}] ;# GPIO21, pin 40
set_property -dict { PACKAGE_PIN U7  IOSTANDARD LVCMOS33 } [get_ports {gpio_io[14]}] ;# GPIO17, pin 11
set_property -dict { PACKAGE_PIN A20 IOSTANDARD LVCMOS33 } [get_ports {gpio_io[15]}] ;# GPIO20, pin 38
set_property -dict { PACKAGE_PIN U8  IOSTANDARD LVCMOS33 } [get_ports {gpio_io[16]}] ;# GPIO22, pin 15

set_property PULLDOWN true [get_ports {gpio_io[*]}]
set_property PULLUP   true [get_ports {qspi_sd_io[*]}]

# JTAG TCK, 10 MHz
create_clock -period 100.000 -name jtag_tck [get_ports jtag_tck_i]
set_clock_groups -asynchronous -group [get_clocks jtag_tck]

set_false_path -from [get_ports {gpio_io[*]}]
set_false_path -to   [get_ports {gpio_io[*]}]
set_false_path -from [get_ports uart_rx_i]
set_false_path -to   [get_ports uart_tx_o]
set_false_path -to   [get_ports {led_o[*]}]

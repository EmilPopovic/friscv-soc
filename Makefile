sources.f: Bender.yml Bender.lock $(wildcard target/ihp-sg13cmos5l/src/*.sv)
	bender script flist-plus -t rtl -t synthesis > $@
	sed -i '\|/tech_cells_generic-[^/]*/src/rtl/tc_sram\.sv$$|d' $@
	sed -i '\|/tech_cells_generic-[^/]*/src/rtl/tc_clk\.sv$$|d' $@
	sed -i '\|/opentitan_peripherals-[^/]*/src/spi_host/rtl/|d' $@
	echo "$(CURDIR)/target/ihp-sg13cmos5l/src/RM_IHPSG13_1P_1024x32_c2_bm_bist.sv" >> $@
	echo "$(CURDIR)/target/ihp-sg13cmos5l/src/sg13cmos5l_stdcell_stubs.sv" >> $@
	echo "$(CURDIR)/target/ihp-sg13cmos5l/src/tc_sram.sv" >> $@
	echo "$(CURDIR)/target/ihp-sg13cmos5l/src/tc_clk.sv" >> $@

.PHONY: act-run-core
act-run-core:
	make -C verif/riscv-arch-test run-core

.PHONY: act-run-soc
act-run-soc:
	make -C verif/riscv-arch-test run-soc

.PHONY: report-area
report-area:
	make -C target/ihp-sg13cmos5l area

.PHONY: librelane
librelane:
	make -C target/ihp-sg13cmos5l librelane

.PHONY: librelane-nodrc
librelane-nodrc:
	make -C target/ihp-sg13cmos5l librelane-nodrc

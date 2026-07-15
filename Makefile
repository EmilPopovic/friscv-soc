sources.f: Bender.yml Bender.lock target/ihp-sg13cmos5l/src/tc_sram.sv target/ihp-sg13cmos5l/src/RM_IHPSG13_1P_1024x32_c2_bm_bist.sv
	bender script flist-plus -t rtl -t synthesis > $@
	sed -i '\|/tech_cells_generic-[^/]*/src/rtl/tc_sram\.sv$$|d' $@
	echo "$(CURDIR)/target/ihp-sg13cmos5l/src/RM_IHPSG13_1P_1024x32_c2_bm_bist.sv" >> $@
	echo "$(CURDIR)/target/ihp-sg13cmos5l/src/tc_sram.sv" >> $@

.PHONY: act-run-core
act-run-core:
	make -C verif/riscv-arch-test run-core

.PHONY: act-run-soc
act-run-soc:
	make -C verif/riscv-arch-test run-soc

.PHONY: report-area
report-area:
	make -C target/ihp-sg13cmos5l area

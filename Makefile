sources.f: Bender.yml Bender.lock $(wildcard target/sim/rtl/*.sv)
	rm sources.f || true
	bender script flist-plus -t rtl -t synthesis > $@
	sed -i '\|/opentitan_peripherals-[^/]*/src/spi_host/rtl/|d' $@
	sed -i '\|/obi_peripherals-[^/]*/hw/obi_uart/|d' $@
	echo "$(CURDIR)/target/sim/rtl/vernii_soc_sim.sv" >> $@

.PHONY: sim
sim:
	make -C target/sim all

.PHONY: act-run-core
act-run-core:
	make -C verif/riscv-arch-test run-core

.PHONY: act-run-soc
act-run-soc:
	make -C verif/riscv-arch-test run-soc

.PHONY: clean
clean:
	make -C target/sim clean
	rm -f sources.f

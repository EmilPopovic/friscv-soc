sources.f: Bender.yml Bender.lock
	bender script flist-plus -t rtl -t synthesis > $@

.PHONY: act-run-core
act-run-core:
	make -C verif/riscv-arch-test run-core

.PHONY: act-run-soc
act-run-soc:
	make -C verif/riscv-arch-test run-soc

.PHONY: report-area
report-area:
	make -C target/asic area

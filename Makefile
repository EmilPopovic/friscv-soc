sources.f: Bender.yml Bender.lock
	bender script flist-plus -t rtl -t synthesis > $@

.PHONY: act-run-all
act-run-all:
	make -C verif/riscv-arch-test run-core

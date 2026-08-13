sources.f: Bender.yml Bender.lock
	rm sources.f || true
	bender script flist-plus -t rtl -t synthesis > $@
	sed -i '\|/opentitan_peripherals-[^/]*/src/spi_host/rtl/|d' $@
	sed -i '\|/obi_peripherals-[^/]*/hw/obi_uart/|d' $@

SLANG_SUPPRESS := .bender/...,rtl/vendored/...

SLANG_LINT_FLAGS := --top vernii_soc --timescale 1ns/1ps \
                    -Wno-duplicate-definition \
                    --suppress-warnings $(SLANG_SUPPRESS) \
                    -Weverything -Werror

VERILATOR_LINT_FLAGS := --lint-only --top-module vernii_soc +define+ASSERTS_OFF

.PHONY: lint
lint: lint-slang lint-verilator lint-zsbl

.PHONY: lint-slang
lint-slang: sources.f
	slang -f sources.f $(SLANG_LINT_FLAGS)

.PHONY: lint-verilator
lint-verilator: sources.f
	verilator $(VERILATOR_LINT_FLAGS) verilator_lint.vlt -f sources.f

# friscv_zsbl_rom_pkg.sv is generated from zsbl.S, catch if they drift apart
.PHONY: lint-zsbl
lint-zsbl:
	python3 sw/boot/gen_zsbl_rom.py sw/boot/zsbl.S \
		rtl/core/friscv_zsbl_rom_pkg.sv rtl/soc/vernii_soc.sv --check

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

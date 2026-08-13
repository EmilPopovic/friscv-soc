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

YOSYS_LINT_LOG := yosys_lint.log

.PHONY: lint
lint: lint-slang lint-synth lint-verilator lint-zsbl

.PHONY: lint-slang
lint-slang: sources.f
	slang -f sources.f $(SLANG_LINT_FLAGS)

SYNTH_LINT_ALLOW := friscv_tlb\.sv

.PHONY: lint-synth
lint-synth: sources.f
	@yosys -p "plugin -i slang; \
	           read_slang -F sources.f --top vernii_soc -Wno-unknown-warning-option; \
	           hierarchy -check -top vernii_soc" > $(YOSYS_LINT_LOG) 2>&1 \
	    || { tail -20 $(YOSYS_LINT_LOG); exit 1; }
	@if grep 'warning:' $(YOSYS_LINT_LOG) | grep '^rtl/' | grep -vE '$(SYNTH_LINT_ALLOW)' > /dev/null; then \
	    echo 'synthesis warnings in rtl/:'; \
	    grep 'warning:' $(YOSYS_LINT_LOG) | grep '^rtl/' | grep -vE '$(SYNTH_LINT_ALLOW)'; \
	    exit 1; \
	fi
	@echo 'lint-synth: no synthesis warnings in rtl/'

.PHONY: lint-verilator
lint-verilator: sources.f
	verilator $(VERILATOR_LINT_FLAGS) verilator_lint.vlt -f sources.f

# vernii_zsbl_rom_pkg.sv is generated from zsbl.S, catch if they drift apart
.PHONY: lint-zsbl
lint-zsbl:
	python3 sw/boot/gen_zsbl_rom.py sw/boot/zsbl.S \
		rtl/soc/vernii_zsbl_rom_pkg.sv rtl/soc/vernii_soc.sv --check

# Generate vernii_zsbl_rom_pkg.sv from zsbl.S
.PHONY: zsbl
zsbl:
	python3 sw/boot/gen_zsbl_rom.py \
		sw/boot/zsbl.S \
		rtl/soc/vernii_zsbl_rom_pkg.sv

.PHONY: sim
sim:
	make -C target/sim all

.PHONY: act-run-core
act-run-core:
	make -C verif/riscv-arch-test run-core

.PHONY: act-run-soc
act-run-soc:
	make -C verif/riscv-arch-test run-soc

.PHONY: directed-run
directed-run:
	make -C verif/directed run

.PHONY: regression
regression:
	make lint
	make -C verif/riscv-arch-test run-core
	make -C verif/riscv-arch-test run-soc
	make -C verif/directed run

.PHONY: clean
clean:
	make -C target/sim clean
	rm -f sources.f

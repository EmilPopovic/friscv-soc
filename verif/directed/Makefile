# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Emil Popović <mail@emilpopovic.me>

TARGET_SIM_ROOT ?= $(CURDIR)/../../target/sim
SIM_DIR         ?= obj_dir_directed
SIM             := $(TARGET_SIM_ROOT)/$(SIM_DIR)/vernii_soc

CROSS   ?= riscv64-unknown-elf-
CFLAGS  := -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles -Wl,--fatal-warnings

TESTS   := llc_tags llc_counters
ELFS    := $(addsuffix .elf,$(TESTS))

# All four ways as cache, so the whole image runs through the LLC
LLCSEL  ?= 0xf
CYCLES  ?= 40000000

%.elf: %.S link.ld
	$(CROSS)gcc $(CFLAGS) -T link.ld -o $@ $<

.PHONY: sim-build
sim-build:
	$(MAKE) -C $(TARGET_SIM_ROOT) soc SOC_DIR=$(SIM_DIR)

.PHONY: all
all: $(ELFS)

.PHONY: run
run: $(ELFS) sim-build
	@fail=0; \
	for t in $(TESTS); do \
	    printf '%-16s ' "$$t"; \
	    if VERNII_LLCSEL=$(LLCSEL) VERNII_TEST_CYCLES=$(CYCLES) \
	       $(SIM) test $$t.elf > $$t.log 2>&1; then \
	        tail -1 $$t.log; \
	    else \
	        tail -1 $$t.log; fail=1; \
	    fi; \
	done; \
	exit $$fail

.PHONY: clean
clean:
	rm -f $(ELFS) *.log
	rm -rf $(TARGET_SIM_ROOT)/$(SIM_DIR)

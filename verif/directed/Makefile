# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Emil Popović <mail@emilpopovic.me>

TARGET_SIM_ROOT ?= $(CURDIR)/../../target/sim
SIM_DIR         ?= obj_dir_directed
SIM             := $(TARGET_SIM_ROOT)/$(SIM_DIR)/vernii_soc

CROSS   ?= riscv64-unknown-elf-
SDK     := $(CURDIR)/../../sw/sdk
CFLAGS  := -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles -Wl,--fatal-warnings -I$(SDK)

TESTS   := llc_tags llc_counters sd_read sysid
ELFS    := $(addsuffix .elf,$(TESTS))

# All four ways as cache, so the whole image runs through the LLC
LLCSEL  ?= 0xf
CYCLES  ?= 40000000

%.elf: %.S link.ld
	$(CROSS)gcc $(CFLAGS) -T link.ld -o $@ $<

%.elf: %.c link.ld
	$(CROSS)gcc $(CFLAGS) -O2 -Wall -Wextra -T link.ld -o $@ $<

# The ROM leaves its stage at zero
uart_stage.bin: uart_stage.S
	$(CROSS)gcc $(CFLAGS) -Wl,-Ttext=0 -o uart_stage.elf $<
	$(CROSS)objcopy -O binary uart_stage.elf $@

# The SD loader itself boots from flash
sdflash.bin: $(SDK)/loaders/sdbl.c $(SDK)/loaders/loader.ld
	$(CROSS)gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 -Os -Wall -Wextra \
		-nostdlib -nostartfiles -Wl,--no-warn-rwx-segments -I$(SDK) \
		-T $(SDK)/loaders/loader.ld -o sdbl.elf $(SDK)/loaders/sdbl.c
	$(CROSS)objcopy -O binary sdbl.elf sdbl.bin
	python3 $(SDK)/tools/mkflash.py sdbl.bin /dev/null $@

sd_payload.img: sd_payload.S
	$(CROSS)gcc $(CFLAGS) -Wl,-Ttext=0x80000000 -o sd_payload.elf $<
	$(CROSS)objcopy -O binary sd_payload.elf sd_payload.bin
	python3 $(SDK)/tools/mksdimg.py sd_payload.bin $@

.PHONY: sim-build
sim-build:
	$(MAKE) -C $(TARGET_SIM_ROOT) soc SOC_DIR=$(SIM_DIR)

.PHONY: all
all: $(ELFS) uart_stage.bin sdflash.bin sd_payload.img

.PHONY: run
run: $(ELFS) uart_stage.bin sdflash.bin sd_payload.img sim-build
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
	printf '%-16s ' uart_boot; \
	if VERNII_TEST_CYCLES=$(CYCLES) \
	   $(SIM) uartboot uart_stage.bin > uart_boot.log 2>&1; then \
	    tail -1 uart_boot.log; \
	else \
	    tail -1 uart_boot.log; fail=1; \
	fi; \
	printf '%-16s ' sd_boot; \
	if VERNII_TEST_CYCLES=$(CYCLES) VERNII_SD_IMAGE=sd_payload.img \
	   $(SIM) qspiboot sdflash.bin > sd_boot.log 2>&1; then \
	    tail -1 sd_boot.log; \
	else \
	    tail -1 sd_boot.log; fail=1; \
	fi; \
	exit $$fail

.PHONY: clean
clean:
	rm -f $(ELFS) uart_stage.elf uart_stage.bin *.log
	rm -f sdbl.elf sdbl.bin sdflash.bin sd_payload.elf sd_payload.bin sd_payload.img
	rm -rf $(TARGET_SIM_ROOT)/$(SIM_DIR)

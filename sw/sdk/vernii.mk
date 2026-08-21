# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Matej Jurasić <matej.jurasic@cappig.dev>

# Builds boot images for bare metal programs

VERNII_SDK := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))

TARGET ?= flash
CACHE  ?= on
NAME   ?= app
OUT    ?= build
CROSS  ?= riscv64-unknown-elf-

ARCH := rv32ima_zicsr_zifencei
ABI  := ilp32

CFLAGS  += -march=$(ARCH) -mabi=$(ABI) -Os -Wall -Wextra
CFLAGS  += -ffreestanding -nostdlib -nostartfiles -I$(VERNII_SDK)
LDFLAGS += -Wl,--fatal-warnings -Wl,--no-warn-rwx-segments

ifeq ($(TARGET),rom)
    LINK    := $(VERNII_SDK)/ocm.ld
    LLCSEL  := 0
else
    LINK    := $(VERNII_SDK)/ext.ld
    LLCSEL  := $(if $(filter on,$(CACHE)),0xf,0)
endif

ifeq ($(filter rom flash sd,$(TARGET)),)
    $(error TARGET must be rom, flash or sd)
endif

# Cache ways take the OCM at zero
ifeq ($(TARGET)$(CACHE),romon)
    $(error TARGET=rom cannot run with CACHE=on)
endif

LOADERS  := $(VERNII_SDK)/loaders
TOOLS    := $(VERNII_SDK)/tools
LOADER_LD := $(LOADERS)/loader.ld
LOADER_CFLAGS := -march=$(ARCH) -mabi=$(ABI) -Os -Wall -Wextra \
                 -ffreestanding -nostdlib -nostartfiles \
                 -Wl,--no-warn-rwx-segments -T $(LOADER_LD)

PROGRAM ?= $(OUT)/$(NAME).elf

.PHONY: all clean
all: $(OUT)/flash.bin $(if $(filter sd,$(TARGET)),$(OUT)/sd.img)

$(OUT):
	mkdir -p $@

$(OUT)/$(NAME).elf: $(SOURCES) $(LINK) $(VERNII_SDK)/crt0.S | $(OUT)
	$(CROSS)gcc $(CFLAGS) $(LDFLAGS) -T $(LINK) -o $@ $(VERNII_SDK)/crt0.S $(SOURCES)

$(OUT)/$(NAME).bin: $(PROGRAM) | $(OUT)
	$(CROSS)objcopy -O binary $< $@

$(OUT)/fsbl.bin: $(LOADERS)/fsbl.S $(LOADER_LD) | $(OUT)
	$(CROSS)gcc $(LOADER_CFLAGS) -Wa,--defsym,LLCSEL=$(LLCSEL) -o $(OUT)/fsbl.elf $<
	$(CROSS)objcopy -O binary $(OUT)/fsbl.elf $@

$(OUT)/sdbl.bin: $(LOADERS)/sdbl.c $(LOADER_LD) | $(OUT)
	$(CROSS)gcc $(LOADER_CFLAGS) -DLLCSEL=$(LLCSEL) -o $(OUT)/sdbl.elf $<
	$(CROSS)objcopy -O binary $(OUT)/sdbl.elf $@

ifeq ($(TARGET),rom)
$(OUT)/flash.bin: $(OUT)/$(NAME).bin
	python3 $(TOOLS)/mkflash.py $< /dev/null $@
else ifeq ($(TARGET),flash)
$(OUT)/flash.bin: $(OUT)/fsbl.bin $(OUT)/$(NAME).bin
	python3 $(TOOLS)/mkflash.py $^ $@
else
$(OUT)/flash.bin: $(OUT)/sdbl.bin
	python3 $(TOOLS)/mkflash.py $< /dev/null $@

$(OUT)/sd.img: $(OUT)/$(NAME).bin
	python3 $(TOOLS)/mksdimg.py $< $@
endif

clean:
	rm -rf $(OUT)

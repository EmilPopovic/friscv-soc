REPO_ROOT := $(abspath ../../..)
BUILD     ?= build
PART      ?= xc7z020clg400-1
BOARD     ?= tul.com.tw:pynq-z2:part0:1.0
TOP       ?= friscv_soc_pynq_ps
VIVADO    ?= vivado

SOC_FREQ_MHZ ?= 50

SRAM_BASE   ?= 0x80000000
SRAM_SIZE   ?= 0x80000
MEM_BASE    ?= 0x80000000
MEM_SIZE    ?= 0x1000000
MEM_PS_BASE ?= 0x100000
ZSBL        ?= 1

BIT   := $(BUILD)/$(TOP).bit
FLIST := sources.f

VIV_ENV = OUTDIR=$(CURDIR)/$(BUILD) FLIST=$(CURDIR)/$(FLIST) PART=$(PART) \
	  BOARD=$(BOARD) TOP=$(TOP) SOC_FREQ_MHZ=$(SOC_FREQ_MHZ) \
	  SRAM_BASE=$(SRAM_BASE) SRAM_SIZE=$(SRAM_SIZE) \
	  MEM_BASE=$(MEM_BASE) MEM_SIZE=$(MEM_SIZE) MEM_PS_BASE=$(MEM_PS_BASE) \
	  ZSBL=$(ZSBL)

.PHONY: all
all: bitstream

$(FLIST): $(REPO_ROOT)/Bender.yml $(REPO_ROOT)/Bender.lock $(wildcard src/*.sv)
	bender script flist-plus -t rtl -t synthesis -t fpga -t xilinx > $@
	sed -i '\|/opentitan_peripherals-[^/]*/src/spi_host/rtl/|d' $@
	sed -i '\|/obi_peripherals-[^/]*/hw/obi_uart/|d' $@
	sed -i '\|/tech_cells_generic-[^/]*/src/fpga/tc_sram_xilinx\.sv$$|d' $@
	echo "$(CURDIR)/src/tc_sram.sv" >> $@
	echo "$(CURDIR)/src/friscv_soc_pynq_ps.sv" >> $@

$(BUILD):
	mkdir -p $@

DEPS := $(FLIST) $(wildcard src/*.sv src/*.v) constraints/$(TOP).xdc

.PHONY: synth impl bitstream
synth impl bitstream: $(DEPS) | $(BUILD)
	$(VIV_ENV) STAGE=$@ $(VIVADO) -mode batch -notrace -nojournal \
		-log $(BUILD)/vivado_$@.log -source vivado/build.tcl

.PHONY: report
report:
	@cat $(BUILD)/reports/summary.txt
	@grep -E '^\| +(Slice LUTs|Slice Registers|Block RAM Tile|DSPs|Bonded IOB) ' \
		$(BUILD)/reports/util.rpt

.PHONY: clean
clean:
	rm -rf $(BUILD) $(FLIST) .Xil clockInfo.txt tight_setup_hold_pins.txt

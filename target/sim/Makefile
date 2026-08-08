CORE_TOP = friscv_cpu_verilator
CORE_DIR = obj_dir_core
CORE_BIN = $(CORE_DIR)/friscv_core

SOC_ONLY_CPP = cpp/axi_mem.cpp cpp/hyperram.cpp cpp/jtag.cpp cpp/remote_bitbang.cpp \
	cpp/soc_memory.cpp cpp/qspi_flash.cpp cpp/soc_testbench.cpp cpp/tb_soc_main.cpp \
	cpp/uart_tx_monitor.cpp
CORE_CPP = $(filter-out $(SOC_ONLY_CPP),$(wildcard cpp/*.cpp))

SHARED_SOC_CPP = cpp/elf_loader.cpp cpp/paged_mem.cpp cpp/jtag.cpp cpp/remote_bitbang.cpp \
	cpp/soc_memory.cpp cpp/qspi_flash.cpp cpp/soc_testbench.cpp cpp/tb_soc_main.cpp \
	cpp/uart_tx_monitor.cpp

SOC_SRAM_BASE ?= 0
SOC_SRAM_SIZE_BYTES ?= 8192
SOC_MEM_SIZE ?= 16777216

SOC_TOP = friscv_soc_sim
SOC_DIR ?= obj_dir_soc
SOC_BIN = $(SOC_DIR)/friscv_soc
SOC_CPP = $(SHARED_SOC_CPP) cpp/axi_mem.cpp

CHIP_TOP = friscv_chip_soc
CHIP_DIR ?= obj_dir_chip
CHIP_BIN = $(CHIP_DIR)/friscv_soc
CHIP_CPP = $(SHARED_SOC_CPP) cpp/hyperram.cpp

SIM_FLAGS = --cc --exe --build -j 0 -Wno-fatal +define+ASSERTS_OFF \
	-GSramBase=$(SOC_SRAM_BASE) -GSramSize=$(SOC_SRAM_SIZE_BYTES) \
	-GMemSize=$(SOC_MEM_SIZE) \
	-CFLAGS -DFRISCV_SOC_SRAM_BASE=$(SOC_SRAM_BASE) \
	-CFLAGS -DFRISCV_SOC_SRAM_SIZE_BYTES=$(SOC_SRAM_SIZE_BYTES)

sources.f: ../../Bender.yml ../../Bender.lock $(wildcard rtl/*.sv)
	bender script flist-plus -t rtl -t synthesis > $@
	sed -i '\|/opentitan_peripherals-[^/]*/src/spi_host/rtl/|d' $@
	sed -i '\|/obi_peripherals-[^/]*/hw/obi_uart/|d' $@
	echo "$(CURDIR)/rtl/friscv_soc_sim.sv" >> $@

$(CORE_DIR):
	mkdir -p $@

core:
	verilator --cc --exe --build -j 0 --top-module $(CORE_TOP) \
		--Mdir $(CORE_DIR) -F ../../friscv.f $(CORE_CPP) -o $(CORE_TOP)

$(SOC_DIR):
	mkdir -p $@

soc: sources.f | $(SOC_DIR)
	verilator $(SIM_FLAGS) --top-module $(SOC_TOP) $(SOC_PARAMS) \
		--Mdir $(SOC_DIR) -f sources.f $(SOC_CPP) -o friscv_soc

$(CHIP_DIR):
	mkdir -p $@

chip: sources.f | $(CHIP_DIR)
	verilator $(SIM_FLAGS) --top-module $(CHIP_TOP) \
		-GHyperClockDelayed=0 $(CHIP_PARAMS) \
		-CFLAGS -DFRISCV_TB_CHIP \
		--Mdir $(CHIP_DIR) -f sources.f $(CHIP_CPP) -o friscv_soc

jtag: soc
	@test -n "$(ELF)" || { echo "usage: make jtag ELF=<program.elf>" >&2; exit 1; }
	$(SOC_BIN) load "$(ELF)"

debug: soc
	@set -eu; \
	$(SOC_BIN) server & \
	sim_pid=$$!; \
	trap 'kill $$sim_pid 2>/dev/null || true; wait $$sim_pid 2>/dev/null || true' EXIT INT TERM; \
	openocd -f openocd.cfg

clean:
	rm -rf $(CORE_DIR) $(SOC_DIR) $(CHIP_DIR) sources.f

all: core soc chip

.PHONY: all core soc chip jtag debug clean

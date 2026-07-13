CORE_TOP = friscv_cpu_verilator
CORE_DIR = obj_dir_core
CORE_BIN = $(CORE_DIR)/friscv_core
CORE_CPP = $(filter-out cpp/jtag.cpp cpp/tb_soc_main.cpp,$(wildcard cpp/*.cpp))

SOC_TOP = friscv_soc
SOC_DIR = obj_dir_soc
SOC_BIN = $(SOC_DIR)/friscv_soc
SOC_CPP = cpp/tb_soc_main.cpp cpp/jtag.cpp cpp/elf_loader.cpp cpp/paged_mem.cpp

sources.f: ../../Bender.yml ../../Bender.lock
	bender script flist-plus -t rtl -t synthesis > $@

$(CORE_DIR):
	mkdir -p $@

core:
	verilator --cc --exe --build -j 0 --top-module $(CORE_TOP) \
		--Mdir $(CORE_DIR) -F ../../friscv.f $(CORE_CPP) -o $(CORE_TOP)

$(SOC_DIR):
	mkdir -p $@

soc: sources.f | $(SOC_DIR)
	verilator --cc --exe --build -j 0 --top-module $(SOC_TOP) -Wno-fatal \
		+define+ASSERTS_OFF \
		--Mdir $(SOC_DIR) -f sources.f $(SOC_CPP) -o $(SOC_TOP)

jtag: soc
	@test -n "$(ELF)" || { echo "usage: make jtag ELF=<program.elf>" >&2; exit 1; }
	$(SOC_BIN) load "$(ELF)"

clean:
	rm -rf $(CORE_DIR) $(SOC_DIR) sources.f

all: core soc

.PHONY: all soc jtag clean

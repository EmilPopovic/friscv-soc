CORE_TOP = friscv_cpu_verilator
CORE_CPP = $(filter-out cpp/jtag.cpp cpp/tb_soc_main.cpp,$(wildcard cpp/*.cpp))

SOC_DIR = obj_dir_soc
SOC_BIN = $(SOC_DIR)/friscv_soc
SOC_CPP = cpp/tb_soc_main.cpp cpp/jtag.cpp cpp/elf_loader.cpp cpp/paged_mem.cpp

all:
	verilator --cc --exe --build -j 0 --top-module $(CORE_TOP) \
		-F ../../friscv.f $(CORE_CPP) -o $(CORE_TOP)

sources.f: ../../Bender.yml ../../Bender.lock
	bender script flist-plus -t rtl -t synthesis > $@

$(SOC_DIR):
	mkdir -p $@

soc: sources.f | $(SOC_DIR)
	verilator --cc --exe --build -j 0 --top-module friscv_soc -Wno-fatal \
		--Mdir $(SOC_DIR) -f sources.f $(SOC_CPP) -o friscv_soc

jtag: soc
	@test -n "$(ELF)" || { echo "usage: make jtag ELF=<program.elf>" >&2; exit 1; }
	$(SOC_BIN) load "$(ELF)"

clean:
	rm -rf obj_dir $(SOC_DIR) sources.f

.PHONY: all soc jtag clean

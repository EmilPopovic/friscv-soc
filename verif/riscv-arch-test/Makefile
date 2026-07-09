ACT_ROOT := riscv-arch-test
ACT_REPO := https://github.com/riscv/riscv-arch-test.git
ACT_REF  := 5f69fff1851122eabe87233c08d6c4096dd0c5ac
ACT_CONFIG_SRC := config/cores/friscv/friscv-full
ACT_CONFIG_DST := $(ACT_ROOT)/config/cores/friscv/friscv-full
ACT_WORK := $(ACT_ROOT)/work/friscv-full
ACT_CONFIG := config/cores/friscv/friscv-full/test_config.yaml
ACT_EXCLUDE_EXTENSIONS ?= Sm,S,InterruptsSm,InterruptsS,InterruptsU,ExceptionsZalrsc,ExceptionsZaamo,Svade,Svadu,SvaduPMP,SvPMP,SvZicbo,SvPMPZicbo,PMPF,PMPS,PMPSm,PMPU,PMPZaamo,PMPZalrsc,PMPZca,PMPZicbo
UV_LINK_MODE ?= copy
JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
TARGET_SIM_ROOT ?= $(shell pwd)/../../target/sim

.PHONY: clone
clone:
	@if [ ! -d $(ACT_ROOT)/.git ]; then \
		git clone ${ACT_REPO} $(ACT_ROOT); \
		cd $(ACT_ROOT) && git checkout $(ACT_REF); \
	fi

.PHONY: distclean
distclean:
	@rm -rf $(ACT_ROOT)

.PHONY: config
config: clone
	mkdir -p $(ACT_CONFIG_DST)
	cp $(ACT_CONFIG_SRC)/* $(ACT_CONFIG_DST)/

.PHONY: all
all: config
	rm -rf elfs/
	rm -rf $(ACT_WORK)/build $(ACT_WORK)/elfs
	UV_LINK_MODE=$(UV_LINK_MODE) CONFIG_FILES=$(ACT_CONFIG) EXCLUDE_EXTENSIONS=$(ACT_EXCLUDE_EXTENSIONS) $(MAKE) -C $(ACT_ROOT) --jobs $(JOBS)
	python3 scripts/copy_elfs.py

.PHONY: run
run:
	python3 scripts/copy_elfs.py
	make -C $(TARGET_SIM_ROOT)
	python3 scripts/run_core.py

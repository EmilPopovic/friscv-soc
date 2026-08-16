ACT_ROOT := riscv-arch-test
ACT_REPO := https://github.com/riscv/riscv-arch-test.git
ACT_REF  := 5f69fff1851122eabe87233c08d6c4096dd0c5ac
ACT_CONFIG_ROOT := config/cores/friscv
ACT_FULL_SRC := $(ACT_CONFIG_ROOT)/friscv-full
ACT_FULL_DST := $(ACT_ROOT)/$(ACT_CONFIG_ROOT)/friscv-full
ACT_FULL_WORK := $(ACT_ROOT)/work/friscv-full
ACT_FULL_CONFIG := $(ACT_CONFIG_ROOT)/friscv-full/test_config.yaml
ACT_SOC_SRC := $(ACT_CONFIG_ROOT)/friscv-soc
ACT_SOC_DST := $(ACT_ROOT)/$(ACT_CONFIG_ROOT)/friscv-soc
ACT_SOC_WORK := $(ACT_ROOT)/work/friscv-soc
ACT_SOC_CONFIG := $(ACT_CONFIG_ROOT)/friscv-soc/test_config.yaml
ACT_SOC_SIM_DIR := obj_dir_soc_act
ACT_SOC_SRAM_BASE := 2147483648
ACT_SOC_SRAM_SIZE_BYTES := 524288
# The suite runs entirely out of the OCM, so build without the LLC
ACT_SOC_OCM_ONLY := 1
ACT_EXCLUDE_EXTENSIONS ?= Sm,S,InterruptsSm,InterruptsS,InterruptsU,ExceptionsZalrsc,ExceptionsZaamo,Svade,Svadu,SvaduPMP,SvPMP,SvZicbo,SvPMPZicbo,PMPF,PMPS,PMPSm,PMPU,PMPZaamo,PMPZalrsc,PMPZca,PMPZicbo
UV_LINK_MODE ?= copy
JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
TARGET_SIM_ROOT ?= $(shell pwd)/../../target/sim

.PHONY: clone
clone:
	@if [ ! -d $(ACT_ROOT)/.git ]; then \
		git init $(ACT_ROOT); \
		git -C $(ACT_ROOT) remote add origin $(ACT_REPO); \
		git -C $(ACT_ROOT) fetch --depth 1 origin $(ACT_REF); \
		git -C $(ACT_ROOT) checkout --detach FETCH_HEAD; \
	fi

.PHONY: distclean
distclean:
	@rm -rf $(ACT_ROOT)

.PHONY: config
config: clone
	rm -rf $(ACT_FULL_DST) $(ACT_SOC_DST)
	mkdir -p $(ACT_FULL_DST) $(ACT_SOC_DST)
	cp $(ACT_FULL_SRC)/* $(ACT_FULL_DST)/
	cp $(ACT_SOC_SRC)/* $(ACT_SOC_DST)/

.PHONY: all
all: all-core all-soc

.PHONY: all-core
all-core: config
	rm -rf elfs/
	rm -rf $(ACT_FULL_WORK)/build $(ACT_FULL_WORK)/elfs
	UV_LINK_MODE=$(UV_LINK_MODE) CONFIG_FILES=$(ACT_FULL_CONFIG) EXCLUDE_EXTENSIONS=$(ACT_EXCLUDE_EXTENSIONS) $(MAKE) -C $(ACT_ROOT) --jobs $(JOBS)
	python3 scripts/copy_elfs.py core

.PHONY: all-soc
all-soc: config
	rm -rf elfs-soc/
	rm -rf $(ACT_SOC_WORK)/build $(ACT_SOC_WORK)/elfs
	UV_LINK_MODE=$(UV_LINK_MODE) CONFIG_FILES=$(ACT_SOC_CONFIG) EXCLUDE_EXTENSIONS=$(ACT_EXCLUDE_EXTENSIONS) $(MAKE) -C $(ACT_ROOT) --jobs $(JOBS)
	python3 scripts/copy_elfs.py soc

.PHONY: run-core
run-core:
	make -C $(TARGET_SIM_ROOT) core
	python3 scripts/run.py core

.PHONY: run-soc
run-soc:
	make -C $(TARGET_SIM_ROOT) soc \
		SOC_DIR=$(ACT_SOC_SIM_DIR) \
		SOC_SRAM_BASE=$(ACT_SOC_SRAM_BASE) \
		SOC_SRAM_SIZE_BYTES=$(ACT_SOC_SRAM_SIZE_BYTES) \
		SOC_OCM_ONLY=$(ACT_SOC_OCM_ONLY)
	python3 scripts/run.py soc

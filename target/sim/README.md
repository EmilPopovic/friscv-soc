# Simulation

This is the simulation target directory. It contains the C++ and
SystemVerilog sources for all testbenches and simulations.

Read more in [`docs/CORE_SIM.md`](../../docs/CORE_SIM.md) or build
with:

```bash
make all
```

Build the full SoC simulator or load an RV32 ELF through JTAG with:

```bash
make soc
make jtag ELF=/path/to/program.elf
```

Direct JTAG memory access:

```bash
obj_dir_soc/friscv_soc read <address> <size>
obj_dir_soc/friscv_soc write <address> <byte> [byte ...]
obj_dir_soc/friscv_soc load <program.elf>
```

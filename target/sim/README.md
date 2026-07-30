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

## HyperRAM model

`cpp/hyperram.cpp` models the device on the HyperBus and enforces its timing. It
raises RWDS during the command phase to request the longer latency, and reports
when the controller turns the bus around before the device would have driven
data. Device timing and the controller's config registers are set from the
environment, so changing them needs no rebuild:

| Variable | Default | |
| --- | --- | --- |
| `FRISCV_HRAM_LATENCY` | 6 | initial latency in clocks |
| `FRISCV_HRAM_FIXED` | 0 | twice the latency on every access |
| `FRISCV_HRAM_REFRESH_EVERY` | 0 | refresh collision every Nth access |
| `FRISCV_HRAM_TCSM` | 0 | maximum CS# low clocks, 0 disables the check |
| `FRISCV_HRAM_STRICT` | 1 | 0 warns instead of aborting |
| `FRISCV_HB_CFG` | | `reg:value[,...]`, register 0 is `t_latency_access` |

```bash
for lat in 3 4 5 6 7; do
    FRISCV_HRAM_LATENCY=$lat FRISCV_HB_CFG=0:$lat \
        obj_dir_soc/friscv_soc test program.elf
done
```

`test` reports the cycle count from reset, for comparing runs.

Start the SoC simulation and debug server from the repository root:

```bash
make -C target/sim debug
```

GDB can then connect from another terminal:

```bash
riscv64-unknown-elf-gdb program.elf
(gdb) target extended-remote 127.0.0.1:3333
(gdb) load
```

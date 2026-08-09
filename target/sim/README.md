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
obj_dir_soc/vernii_soc read <address> <size>
obj_dir_soc/vernii_soc write <address> <byte> [byte ...]
obj_dir_soc/vernii_soc load <program.elf>
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
        obj_dir_soc/vernii_soc test program.elf
done
```

`test` reports the cycle count from reset, for comparing runs.

## apheleiaOS

`scripts/aos.sh` fetches and builds apheleiaOS into a gitignored `build_aos/`,
then boots it; an existing image is booted rather than rebuilt. Pass `rebuild`
to force a new one. Building needs clang, ld.lld and dtc.

```bash
scripts/aos.sh
```

`scripts/run_aos.sh` boots an image that is already built, and takes the same
environment as `test`:

```bash
scripts/run_aos.sh build_aos/apheleiaOS/bin/apheleia_1.0_riscv_32.img
```

The image runs from external memory with the whole SRAM left as cache, so the
memory is sized past its default. Its boot stub assumes a boot ROM programmed
the UART divisor and never does it itself, which is what `UART_DIV` covers.
Reaching the login prompt takes about half an hour.

| Variable | Default | |
| --- | --- | --- |
| `MEM_SIZE` | 268435456 | external memory bytes |
| `LLCSEL` | 0xf | ways used as cache rather than scratchpad |
| `UART_DIV` | 27 | 16550 divisor, 115200 baud from 50 MHz |
| `CYCLES` | 20000000000 | cycle limit |
| `BOOT` | jtag | `qspi` to boot through the ROM and the flash |

`BOOT=qspi` is the path the chip itself takes. Rather than having the debug
module place the image in memory, it packs the second stage and the image into
a flash image, and the boot ROM reads it over QSPI:

```bash
BOOT=qspi scripts/run_aos.sh build_aos/apheleiaOS/bin/apheleia_1.0_riscv_32.img
```

The ROM copies the first block into the OCM and jumps to it; that stage turns
on the external memory, sets the divisor, streams the image into RAM and hands
over. `LLCSEL` does not apply, the second stage switches the ways itself.
Streaming 3 MB over SPI adds a few minutes before the console starts.

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

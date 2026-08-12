# Vernii

Vernii is a minimal Linux-capable 32-bit RISC-V SoC built around the [FRISC-V](https://github.com/friscv/friscv-system-hw) core, using [PULP](https://github.com/pulp-platform) and [OpenTitan](https://github.com/lowRISC/opentitan) peripherals. The system is heavily based on [Cheshire](https://github.com/pulp-platform/cheshire).

Vernii is developed as part of the FERICA project, an initiative by the [Faculty of Electrical Engineering and Computing](https://www.fer.unizg.hr/en), [University of Zagreb](https://www.unizg.hr/homepage/).

## Not Implemented

- **QSPI input synchronization** - They go straight into `spi_host`, as OpenTitan requires. Must constrain with respect to SCK instead.
- **AXI atomics** - Atomic instructions (`lr`, `sc`, `amo`) are atomic only from the view of the core (i.e. during interrupts), and not to other devices in the system.
- **DFT** - No scan implemented.
- **Zero initialization** - Non-`x0` GPRs and OCM initialize to `X`. Write before reading.

## License

Unless specified otherwise in the respective file headers, all code checked into this repository is made available under a permissive license. All hardware sources and tool scripts are licensed under the Solderpad Hardware License 2.1 (see [`LICENSE`](LICENSE)) or compatible licenses. Peripherals are either imported or vendored and patched from [PULP](https://github.com/pulp-platform/) licensed under the Solderpad Hardware License 0.51 (see [`LICENSE.PULP`](LICENSE.PULP)), or [lowRISC](https://github.com/lowRISC) (OpenTitan) and Emil Popović licensed under Apache 2.0 (see [`LICENSE.lowRISC`](LICENSE.lowRISC)).

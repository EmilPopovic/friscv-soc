# Vernii

Vernii is a minimal Linux-capable 32-bit RISC-V SoC built around the [FRISC-V](https://github.com/friscv/friscv-system-hw) core, using [PULP](https://github.com/pulp-platform) and [OpenTitan](https://github.com/lowRISC/opentitan) peripherals. The system is heavily based on [Cheshire](https://github.com/pulp-platform/cheshire).

<!-- markdownlint-disable MD033 -->
<picture>
    <source media="(prefers-color-scheme: dark)" srcset="./docs/figures/block-diagram-transparent-dark.svg">
    <img alt="Block Diagram" src="./docs/figures/block-diagram-transparent-light.svg" height="500">
</picture>
<!-- markdownlint-enable MD033 -->

Vernii is developed as part of the FERICA project, an initiative by the [Faculty of Electrical Engineering and Computing](https://www.fer.unizg.hr/en), [University of Zagreb](https://www.unizg.hr/homepage/).

## Quick Start

- To learn how to build and use Vernii, see [Getting Started](docs/GETTING_STARTED.md).
- To learn about available simulation, FPGA, and ASIC targets, see [Targets](docs/TARGETS.md).
- For detailed information on Vernii's inner workings, consult the [User Manual](docs/USER_MANUAL.md).
- Or explore the [documentation](docs/DOCS_HOME.md).

## License

Unless specified otherwise in the respective file headers, all code checked into this repository is made available under a permissive license. All hardware sources and tool scripts are licensed under the Solderpad Hardware License 2.1 (see [`LICENSE`](LICENSE)) or compatible licenses. Peripherals are either imported or vendored and patched from [PULP](https://github.com/pulp-platform/) licensed under the Solderpad Hardware License 0.51 (see [`LICENSE.PULP`](LICENSE.PULP)), or [lowRISC](https://github.com/lowRISC) (OpenTitan) and Emil Popović licensed under Apache 2.0 (see [`LICENSE.lowRISC`](LICENSE.lowRISC)).

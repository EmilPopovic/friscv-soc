<!-- markdownlint-disable MD041 -->
[Home](DOCS_HOME.md)
<!-- markdownlint-enable MD041 -->

# Targets

A target refers to an end use of Vernii. This could be a simulation setup, an FPGA or ASIC implementation, or the integration into other SoCs.

Target setups can either be included in this repository or live in an external repository and use Vernii as a dependency.

## Included Targets

Included target setups live in the `target/` directory.

Each included target has a documentation page in this chapter:

- [Simulation](SIMULATION.md)
- [Xilinx FPGAs](XILINX_FPGAS.md)

## External Targets

For integration into other SoCs, Vernii may be included either as a Bender dependency or Git submodule. For further information and best practices, see [SoC Integration](SOC_INTEGRATION.md).

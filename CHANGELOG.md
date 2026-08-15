<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Refactored `rtl/core/`.
- Moved parameter check to `friscv_core.sv`.
- Moved the ZSBL ROM out of the CPU core and onto the SoC register bus.
- Serializing and counter CSR checks now done in the decoder.

### Added

- Add preliminary support for RV32E.

## [0.2.0] - 2026-08-14

### Changed

- **Breaking:** Rename `axi_mem*` to `m_axi_hp*`.
- Rename `EnableExtM`/`EnableExtA` to `EnableIsaM`/`EnableIsaA`.

### Added

- Add general-purpose AXI Lite subordinate port, `s_axi_gp_*`, gated by `EnableSAxiGp`.
  It reaches the bus through the memory hub, and is coherent with the CPU's view of external memory.
- `SAxiGpRules` determines what the GP port can reach. Access outside every rule (or when disabled) is
  answered with a DECERR.

## [0.1.0] - 2026-08-13

### Added

- Initial release.

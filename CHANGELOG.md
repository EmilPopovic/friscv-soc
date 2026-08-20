<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `sdbl.c`, a first stage that boots from an SD card in SPI mode on QSPI0 CS1.
  The ROM loads it from flash, so the card carries only the image, laid out by
  `mksdimg.py`.
- An SD card model, the `sd_read` directed test, and `sd_boot`, which boots a
  payload off the card through `sdbl.c`.
- Add `OcmOnly` parameter on `vernii_soc`.
- Boot select 2 loads the first stage over UART0, 8N1 at 115200. The ROM window
  is 256 bytes now.
- UART boot sends `V` before receiving, so a terminal shows whether the ROM is
  running and the baud rate agrees.
- Wire all UART lines to top-level ports.
- Pass through all relevant core parameters to top level.

### Changed

- **Breaking:** The boot ROM reads a 4 KiB first stage rather than 512 bytes, so
  the flash image header moves from `0x200` to `0x1000`.
- The boot ROM points `mtvec` at its park loop, so a trap during boot leaves the
  hart parked for the debug module.
- **Breaking:** `0x0300_0000` to `0x03FF_FFFF` is reserved for Vernii and
  `MRegRules` may no longer map into it. Integrator peripherals start at
  `0x0400_0000`.

- **Breaking:** The boot ROM holds a fixed 4 KiB slot rather than one sized by
  its contents, so the memory map no longer moves with the image. Reads past the
  image return an error.

- Bumped `friscv-mem-utils` to `v4.1.0`, now using packed struct pairs instead of `friscv_mem_if` interface. There are no more `interface`s in the design.
- **Breaking:** Moved every peripheral into one block 64 KiB apart: SCB `0x0300_0000`,
  UART0 `0x0301_0000`, QSPI0 `0x0302_0000`, GPIO port A `0x0303_0000`, ZSBL ROM
  `0x0304_0000`, debug module `0x0305_0000`. The OCM, the ACLINT, the PLIC and external
  memory keep their addresses.
- **Breaking:** The reset vector moved with the ROM, to `0x0304_0000`.
- **Breaking:** Renamed `ExtRegSlvRules` to `MRegRules`, `NumExtRegSlv` to
  `NumMRegRules` and `reg_ext_*` to `m_reg_*`, to match `SAxiGpRules` and `m_axi_hp_*`.
- **Breaking:** Removed the `ZsblBaseAddr` parameter, the ROM has a fixed slot now.
- **Breaking:** Replaced the SCB strap register with boot select.
- Refactored core to use [lowRISC style guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md).
- Add reset duplication.

### Fixed

- An access fault from an instruction fetch that a redirect has already
  discarded no longer traps.

## [0.3.0] - 2026-08-15

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

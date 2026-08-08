# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The PYNQ-Z2 target now remaps its external memory window to PS address
  `0x0010_0000` instead of `0x0000_0000`, keeping clear of the first 1 MiB of
  DRAM, which is reserved.
- The low PYNQ-Z2 GPIO bits now reach the on-board user I/O: buttons on 3:0,
  switches on 5:4, discrete LEDs on 9:6, with PMODB and the Raspberry Pi header
  shifted up to 14:10 and 26:15. The bring-up indicators move to the RGB LEDs.

## [0.1.0] - 2026-08-08

### Added

- Initial split from original repo.

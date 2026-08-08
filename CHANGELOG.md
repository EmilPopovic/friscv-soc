# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The PYNQ-Z2 target now remaps its external memory window to PS address
  `0x0010_0000` instead of `0x0000_0000`, keeping clear of the first 1 MiB of
  DRAM, which is reserved.

## [0.1.0] - 2026-08-08

### Added

- Initial split from original repo.

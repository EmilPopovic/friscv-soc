# FRISC-V Tapeout

The first tapeout of the FRISC-V core, targeting IHP's open-source **SG13G2**
130nm process.

## Setup

The toolchain is provided by **Nix**. This flow is inspired by
[LibreLane](https://librelane.readthedocs.io) which uses the same mechanism.

This should work on all Linux distros, including WSL, but was only tested on
Ubuntu 26.04 LTS and Arch using zsh.

**Prerequisites:**

- `curl` (to bootstrap the Nix installer)
- `direnv` (for automatic activation, usually `<pkg-manager> install direnv`)

Clone and run the setup script:

```bash
git clone https://github.com/EmilPopovic/friscv-tapeout.git
cd friscv-tapeout
./setup.sh
```

`setup.sh` will:

1. Install **Nix** if it isn't present - a one-time step that asks for `sudo`.
   Everything after this needs no sudo. It enables flakes and adds the FOSSi binary cache.
2. Generate `flake.lock`
3. Install and hook up **nix-direnv** so the environment auto-activates.

### Activating the environment

Make sure your shell has the direnv hook (add to your shell rc):

```bash
eval "$(direnv hook zsh)"   # zsh  -> ~/.zshrc
eval "$(direnv hook bash)"  # bash -> ~/.bashrc
```

Then, in the repo root:

```bash
direnv allow
```

The first activation downloads the prebuilt tools (a few minutes). After that,
`cd`-ing into the repo puts every tool on your `PATH` automatically.

### Tools provided

Synthesis and simulation: **Yosys**, **Icarus Verilog**, **Verilator**, **ngspice**,
**GTKWave**. Physical design and sign-off: **OpenROAD**, **KLayout**, **Magic**,
**Netgen** (LVS).

To change the tool set, edit the `packages` list in `flake.nix`, then
`direnv reload`. Commit the updated `flake.lock`.

## Documentation

- [Core-level simulation](docs/CORE_SIM.md) - the C++/Verilator testbench in
  `target/sim/` that drives a bare FRISC-V CPU subsystem over a virtual bus.
- [Architecture certification tests](docs/RISCV_ARCH_TEST.md) — running the
  official `riscv-arch-test` suite against the core or full SoC.

## Repository layout

- `rtl/` - Core (`rtl/core/`) and SoC (`rtl/soc/`) SystemVerilog sources.
- `target/asic/` - ASIC synthesis flow.
- `target/sim/` - Core-level C++/Verilator simulation harness.
- `target/xilinx/` - FPGA target (WIP).
- `verif/` - Verification, including `riscv-arch-test`.
- `sw/` - Software / test programs.
- `flake.nix` - Nix toolchain definition.

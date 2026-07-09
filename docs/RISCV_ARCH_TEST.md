# Architecture Certification Tests

## Core-level

The [core-level testbench](CORE_SIM.md) can be used to run `riscv-arch-test`,
the official certification test suite. The default full configuration of the
FRISC-V core is tested, per `verif/riscv-arch-test/config/cores/friscv/friscv-full/`.

To run the core-level certification tests, the tests must be built first:

```bash
make -C verif/riscv-arch-test all  # run once
```

Then run the tests at any time:

```bash
make -C verif/riscv-arch-test run-core
# or
make act-run-core
```

That target automatically builds the testbench binary and
verilates the current design.

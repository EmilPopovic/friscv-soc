#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path

from colored import green, red

ROOT = Path(__file__).resolve().parent.parent
SIM_ROOT = ROOT.parent.parent / "target" / "sim"

TARGETS = {
    "core": (
        ROOT / "elfs",
        SIM_ROOT / "obj_dir_core" / "friscv_cpu_verilator",
    ),
    "soc": (
        ROOT / "elfs-soc",
        SIM_ROOT / "obj_dir_soc_act" / "vernii_soc",
    ),
}


def no_elfs():
    print("No elfs found.")
    print("Generate by running")
    print("  make -C verif/riscv-arch-test all")
    sys.exit(1)


def command(target, executable, elf):
    if target == "core":
        return [
            executable,
            "--elf",
            elf,
            "--check-pass",
            "--wait-cycles",
            "-2",
        ]

    return [executable, "test", elf]


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in TARGETS:
        print(f"usage: {sys.argv[0]} <core|soc>", file=sys.stderr)
        sys.exit(1)

    target = sys.argv[1]
    elfs_dir, executable = TARGETS[target]

    if not executable.exists():
        print("Executable not found.")
        print("Build by running")
        print(f"  make -C target/sim {target}")
        sys.exit(1)

    if not elfs_dir.exists():
        no_elfs()

    elfs = sorted(elfs_dir.rglob("*.elf"))
    print(f"Found {len(elfs)} elfs in {elfs_dir}")

    if not elfs:
        no_elfs()

    passed = 0

    for elf in elfs:
        result = subprocess.run(
            command(target, executable, elf),
            capture_output=True,
            text=True,
            check=False,
        )

        if result.returncode == 0 and "PASS" in result.stderr:
            print(f"{green('PASS')} {elf.stem}")
            passed += 1
        else:
            print(f"{red('FAIL')} {elf.stem}")

    print()
    print(f"Passed {passed}/{len(elfs)} tests")

    if passed != len(elfs):
        sys.exit(1)

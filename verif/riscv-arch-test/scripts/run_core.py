#!/usr/bin/env python3
import sys
import subprocess
from pathlib import Path
from colored import red, green

ROOT = Path(__file__).resolve().parent.parent
ELFS_DIR = ROOT / "elfs"
PROJECT_ROOT = ROOT.parent.parent
OBJ_DIR = PROJECT_ROOT / "target" / "sim" / "obj_dir_core"
EXE = OBJ_DIR / "friscv_cpu_verilator"

def no_elfs():
    print("No elfs found.")
    print("Generate by running")
    print("  make -C verif/riscv-arch-test all")
    sys.exit(1)

if __name__ == "__main__":
    if not EXE.exists():
        print(f"Executable not found.")
        print("Build by running")
        print("  make -C target/sim core")
        sys.exit(1)

    if not ELFS_DIR.exists():
        no_elfs()

    elf_count = len(list(ELFS_DIR.rglob("*.elf")))
    print(f"Found {elf_count} elfs in {ELFS_DIR}")

    if elf_count == 0:
        no_elfs()

    passed = 0

    for elf in sorted(ELFS_DIR.rglob("*.elf")):
        result = subprocess.run(
            [EXE, "--elf", str(elf), "--check-pass", "--wait-cycles", "-2"],
            capture_output=True, text=True, check=False,
        )
        if ("PASS" in result.stderr):
            print(f"{green('PASS')} {elf.stem}")
            passed += 1
        else:
            print(f"{red('FAIL')} {elf.stem}")

    print()
    print(f"Passed {passed}/{elf_count} tests")
    if passed != elf_count:
        sys.exit(1)

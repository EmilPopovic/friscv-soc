# FRISC-V Tapeout

The first tapeout of the FRISC-V core.

## Setup

This repo is meant to be used on Linux systems, preferably Ubuntu 24 or newer. WSL and other Linux distros should work (but you will have to bring your own package manager instead of `apt`).

**Prerequisites:**

- `direnv` (`sudo apt install direnv`)
- `wget` (`sudo apt-get install wget`)
- `tar` (`sudo apt install tar`)

No additional tools are needed, the repo manages its own environment for reproducability. Set it up by cloning and running the setup script:

```bash
git clone https://github.com/EmilPopovic/friscv-tapeout.git
cd friscv-tapeout
./setup.sh
```

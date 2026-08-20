<!-- markdownlint-disable MD041 -->
[Home](DOCS_HOME.md) / [User Manual](USER_MANUAL.md)
<!-- markdownlint-enable MD041 -->

# Software Stack

Vernii's software stack currently provides:

- A zero-stage bootloader (ZSBL) in ROM
- An example first-stage bootloader (FSBL) for QSPI-based images
- An example first stage (`sdbl.c`) that boots from an SD card

## Boot Protocol

The reset vector is the ROM at `0x0304_0000`. It loads a 4 KiB first stage to
address zero and enters it there. The stage loads an image to `ExtBase` and
enters that.

A stage is always 4 KiB; `mkflash.py` pads it. The OCM is 8 KiB, so the rest is
the stage's to use.

`mtvec` points at the park loop for the whole of boot. A stage that faults, or a
blank medium read back as illegal instructions, parks for the debug module.

The default ROM is an example; an integrator replaces it through `ZsblRomWords`
and `ZsblRomProg`. The hardware fixes only the reset vector, the ROM slot and
the straps.

### Boot select

| `SCB.BOOTSEL` | Source |
| ------------- | ------ |
| `0` | Debug module |
| `1` | QSPI0 flash on CS0, offset 0 |
| `2` | UART0 |

### Debug module

The ROM writes `1` to `SCB.SCRATCH0` and spins until it changes. A debugger
loads code, then writes the entry point over the `1`. `1` is misaligned, so it
cannot collide with a real entry point.

### UART

8N1 at `F_CPU / 432`: 115200 at 50 MHz. The divisor is derived from `F_CPU`, so
the baud rate follows the core clock.

The ROM sends `V` before receiving, then reads 4 KiB. No framing, no handshake,
no timeout; a short transfer waits forever and needs the debug module to
recover. Tolerates a host clock error of -3.8% to +5.1%.

### Flash layout

| Offset | Contents |
| ------ | -------- |
| `0x0000` | Stage, padded to 4 KiB |
| `0x1000` | Header |
| `0x100c` | Image |

The payload sits at a fixed offset so a stage can find it without being told;
the ROM neither knows nor cares where it is.

### SD card layout

| Block | Contents |
| ----- | -------- |
| `0` | Header |
| `1`+ | Image |

### Header

Three little-endian words, shared by both layouts:

| Word | Meaning |
| ---- | ------- |
| 0 | `0x43535246`, "FRSC" |
| 1 | Image length in bytes |
| 2 | Sum of the image words, truncated to 32 bits |

On a bad magic, length or sum, the example stages write an odd value to
`SCB.SCRATCH0` and park.

### Writing a stage

- Link the stage at 0.
- The ROM provides no stack. Set `sp` before running C.
- The ROM jumps as soon as it has drained its last word, so the SPI host may
  still be active. Wait for it to go idle before changing `CSID`.
- Enter the image with `a0` the hart id and `a1` a device tree pointer, or zero
  if the image carries its own.
- Cache ways cannot be enabled from address zero, since the OCM backing them
  would disappear. Copy a trampoline past the image and set `SCB.LLCSEL` from
  there.

## Baremetal Programs

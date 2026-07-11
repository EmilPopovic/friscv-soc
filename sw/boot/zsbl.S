.section .text
.global _start

.option arch, +zicsr

.equ SCRATCH_ADDR, 0x40000000

_start:
    li t0, SCRATCH_ADDR  # scratch
    li t1, 1             # 1 cannot be a jump target, misaligned
    sw t1, 0(t0)         # parked
1:  lw t2, 0(t0)
    beq t2, t1, 1b       # spin while scratch == 1
    fence.i              # DM changed code, refetch just in case
    jr t2                # jump to scratch (set by the DM)

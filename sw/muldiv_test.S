#============================================================================
#  v0.4 pipeline MUL/DIV test
#  - MUL adjacent dependency (1-cycle stall)
#  - DIV blocks the pipeline but older instructions retire normally
#  - x30 counts how many times the two ADDI around the DIV retire
#============================================================================
    .option norvc
    .section .text.init, "ax"
    .globl _start

_start:
    li      x1, 6
    li      x2, 7
    mul     x3, x1, x2          # 42
    add     x4, x3, x1          # 48  (mul -> add dependency)

    li      x5, 100
    li      x6, 7
    div     x7, x5, x6          # 14
    rem     x8, x5, x6          # 2
    add     x9, x7, x8          # 16

    li      x10, -7
    div     x11, x10, x6        # -1
    rem     x12, x10, x6        # 0

    li      x13, -7
    li      x14, 2
    div     x15, x13, x14       # -3
    rem     x16, x13, x14       # -1

    li      x17, -1
    srli    x18, x17, 1         # 0x7FFFFFFF
    divu    x19, x17, x18       # 2
    remu    x20, x17, x18       # 1

    div     x21, x1, x0         # 6 / 0 = -1
    rem     x22, x1, x0         # 6

    li      x23, -1
    li      x24, -1
    mulh    x25, x23, x24       # 0
    mulhu   x26, x23, x24       # 0xFFFFFFFE

    li      x30, 0
    addi    x30, x30, 1         # x30 = 1
    div     x7, x5, x6          # 33-cycle block
    addi    x30, x30, 1         # x30 = 2 (must not be double-counted)

    ebreak

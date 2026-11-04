#============================================================================
#  v0.5 MUL fast-path test: back-to-back MULs, MUL -> dependent consumer,
#  MULH mixed in (still on the two-cycle path), and reuse of the same rd.
#============================================================================
    .option norvc
    .section .text.init, "ax"
    .globl _start

_start:
    li      x1, 0x1234
    li      x2, 0x5678
    li      x3, 3

    # ---- back-to-back, no dependency
    mul     x10, x1, x2         # 0x1234*0x5678 = 0x06260060
    mul     x11, x1, x3         # 0x369C
    mul     x12, x2, x3         # 0x10368

    # ---- MUL immediately followed by a dependent MUL
    mul     x13, x10, x3        # 0x06260060*3 = 0x12720120
    mul     x14, x13, x3        # 0x12720120*3 = 0x3756_0360

    # ---- same destination twice in a row
    mul     x15, x1, x3         # 0x369C
    mul     x15, x2, x3         # 0x10368  (must win)

    # ---- MULH still uses the registered 64-bit product
    mulh    x16, x1, x2         # high half of 0x1234*0x5678 = 0x0000_0626
    mulhu   x17, x1, x2         # 0x0000_0626
    li      x18, -1
    li      x19, -1
    mulh    x20, x18, x19       # -1*-1 = 1 -> high 0
    mulhsu  x21, x18, x1        # -1 * 0x1234 -> high 0xFFFF_FFFF

    # ---- MUL result used as an address offset right away
    li      x22, 0x00010000
    add     x23, x22, x10       # 0x00010000 + 0x06260060
    ebreak

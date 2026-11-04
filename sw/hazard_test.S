#============================================================================
#  v0.4p hazard test: load -> MUL/DIV operand capture, wrong-path MUL/DIV,
#  and spurious load-use stalls from immediate bits decoded as rs2.
#
#  Everything runs against the four-stage core with a real data RAM, so the
#  load data is only valid in MEM/WB (synchronous read, same as the FPGA).
#============================================================================
    .option norvc
    .section .text.init, "ax"
    .globl _start

_start:
    li      x2, 0x00010000      # data RAM base
    li      x3, 0x1234
    li      x5, 3
    sw      x3, 0(x2)

    # ---- T1: LW -> MUL, rs1 dependency.  x4 must be 0x1234 * 3 = 0x369C
    lw      x1, 0(x2)
    mul     x4, x1, x5

    # ---- T2: LW -> DIV, rs2 dependency.  x9 must be 75 / 3 = 25
    li      x6, 25
    mul     x7, x6, x5          # x7 = 75
    sw      x7, 4(x2)
    lw      x8, 4(x2)
    div     x9, x8, x5

    # ---- T3: LW -> MULHU (both sources).  high half of 0x1234*3 = 0
    lw      x12, 0(x2)
    mulhu   x13, x12, x5

    # ---- T4: MUL on the wrong side of a taken branch must never retire
    li      x15, 0
    beq     x0, x0, 1f
    mul     x15, x6, x6
1:

    # ---- T5: LW -> ADDI whose immediate is the load's rd: no real
    #          dependency, so this pair must not stall
    li      x17, 100
    lw      x16, 8(x2)          # x16 = 0 (never written)
    addi    x17, x17, 16        # imm[4:0] == 16 == x16 -> old stall

    # ---- T6: LW -> branch, real dependency (taken)
    li      x21, 0
    lw      x22, 0(x2)          # 0x1234
    bne     x22, x5, 2f
    li      x21, 99             # must not execute
2:
    li      x21, 1

    ebreak

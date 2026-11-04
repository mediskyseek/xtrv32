#============================================================================
#  v0.4 pipeline branch test
#  Taken / not-taken conditionals, JAL, JALR.  x3 must end at 6: any executed
#  wrong-path instruction would overwrite it with 99.
#============================================================================
    .option norvc
    .section .text.init, "ax"
    .globl _start

_start:
    li      x1, 5
    li      x2, 5
    li      x3, 0

    beq     x1, x2, t1          # taken
    addi    x3, x0, 99
t1:
    addi    x3, x3, 1           # x3 = 1

    li      x4, 1
    li      x5, 2
    blt     x4, x5, t2          # taken
    addi    x3, x0, 99
t2:
    addi    x3, x3, 1           # x3 = 2

    beq     x4, x5, nt1         # not taken (1 != 2)
    addi    x3, x3, 1           # x3 = 3
nt1:
    bge     x4, x5, sk1         # not taken
    addi    x3, x3, 1           # x3 = 4
sk1:
    bltu    x2, x4, sk2         # not taken (5 < 1 false)
    addi    x3, x3, 1           # x3 = 5
sk2:
    jal     x6, jt              # x6 = return address
    addi    x3, x0, 99
jt:
    addi    x3, x3, 1           # x3 = 6

    la      x7, jrt
    jalr    x8, 0(x7)           # x8 = return address
    addi    x3, x0, 99
jrt:
    ebreak

#============================================================================
#  v0.4 pipeline memory test -- LOAD/STORE + load-use forwarding
#  RAM base 0x0001_0000
#============================================================================
    .option norvc
    .section .text.init, "ax"
    .globl _start

_start:
    li      x2, 0x00010000          # RAM base

    li      x10, 0xDEADBEEF
    sw      x10, 0(x2)              # store word
    lw      x1, 0(x2)               # load, immediately used
    add     x3, x1, x1              # load-use (forwarded from RAM output)

    li      x11, 0x1234
    sw      x11, 4(x2)
    lw      x4, 4(x2)
    add     x5, x4, x3              # depends on load x4 and add x3

    li      x12, 0xAA
    sb      x12, 1(x2)              # byte store
    lbu     x6, 1(x2)               # zero extend  -> 0xAA
    lb      x7, 1(x2)               # sign extend  -> 0xFFFFFFAA

    li      x13, 0xBEEF
    sh      x13, 2(x2)              # half store
    lhu     x8, 2(x2)               # 0xBEEF
    lh      x9, 2(x2)               # 0xFFFFBEEF

    addi    x14, x7, 1              # 0xFFFFFFAB
    ebreak

#============================================================================
#  v0.4 pipeline skeleton test -- ALU instructions only
#  Exercises: 相邻依赖（前递）、写 x0、LUI/AUIPC/移位/比较
#============================================================================
    .option norvc
    .section .text.init, "ax"
    .globl _start

_start:
    addi x1, x0, 5
    addi x2, x1, 3          # 相邻依赖 x1
    add  x3, x2, x1         # 相邻依赖 x2
    sub  x4, x3, x2
    addi x5, x0, -1
    xor  x7, x1, x2
    and  x8, x7, x1
    or   x9, x8, x2
    slli x10, x1, 2
    srli x11, x10, 1
    srai x12, x5, 1
    slt  x13, x5, x1
    sltu x14, x5, x1
    lui  x15, 0x12345
    addi x16, x0, 7
    addi x17, x16, -7
    addi x0, x0, 99         # 写 x0 必须无效
    ebreak

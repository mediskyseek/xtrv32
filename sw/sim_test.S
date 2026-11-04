#============================================================================
#  MyXTRV32 v0.1  simulation-only firmware
#  Same UART/LED paths as main.S but without the half-second delays, so the
#  behavioural simulation finishes in a few thousand clock cycles.
#============================================================================
    .option norvc
    .section .text.init, "ax"
    .globl _start

_start:
    li      sp, 0x00020000
    li      s0, 0x00020000          # UART base
    li      s1, 0x00020100          # GPIO base

    # ------------------------------------------------------- RAM read/write
    li      t0, 0x00010000
    li      t1, 0xDEADBEEF
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    bne     t1, t2, fail

    li      t1, 0x0000005A
    sb      t1, 3(t0)
    lw      t2, 0(t0)
    li      t3, 0x5AADBEEF
    bne     t2, t3, fail

    # ------------------------------------------------------------- banner
    la      a0, msg_ok
    jal     ra, puts

    # --------------------------------------------------------- LED walking
    li      t0, 1
    sw      t0, 0(s1)
    li      t1, 4
1:  xori    t0, t0, 1
    sw      t0, 0(s1)
    addi    t1, t1, -1
    bnez    t1, 1b

    la      a0, msg_done
    jal     ra, puts

    ebreak

fail:
    li      t0, 2
    sw      t0, 0(s1)
    la      a0, msg_fail
    jal     ra, puts
    ebreak

#----------------------------------------------------------------------------
#  puts: a0 = NUL terminated string
#----------------------------------------------------------------------------
puts:
    mv      s4, a0
1:  lbu     t2, 0(s4)
    beqz    t2, 2f
3:  lw      t3, 4(s0)
    andi    t3, t3, 1
    bnez    t3, 3b
    sb      t2, 0(s0)
    addi    s4, s4, 1
    j       1b
2:  ret

#----------------------------------------------------------------------------
    .section .rodata
msg_ok:
    .asciz  "MyXTRV32 SIM OK\r\n"
msg_done:
    .asciz  "DONE\r\n"
msg_fail:
    .asciz  "RAM FAIL\r\n"

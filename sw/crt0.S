#============================================================================
#  MyXTRV32 v0.2  C runtime startup
#    - set up stack at the top of RAM (0x0002_0000)
#    - copy .data from its ROM load address to RAM
#    - zero .bss
#    - call main()
#============================================================================
    .option norvc
    .section .text.init, "ax"
    .globl _start

_start:
    la      sp, _stack_top

    # ---------------------------------------------------------- copy .data
    la      t0, __data_load
    la      t1, __data_start
    la      t2, __data_end
1:  bgeu    t1, t2, 2f
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       1b
2:
    # ----------------------------------------------------------- zero .bss
    la      t0, __bss_start
    la      t1, __bss_end
3:  bgeu    t0, t1, 4f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       3b
4:
    # ------------------------------------------------------------ run main
    call    main

5:  j       5b

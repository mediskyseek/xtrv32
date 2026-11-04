/*============================================================================
 *  MyXTRV32 v0.2  linker script
 *    ROM 0x0000_0000  64 KiB  (code + rodata + .data load image)
 *    RAM 0x0001_0000  64 KiB  (data + bss + stack)
 *============================================================================*/
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 64K
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text*)
        *(.rodata*)
        *(.srodata*)
    } > ROM

    .data : {
        __data_start = .;
        *(.data*)
        *(.sdata*)
        __data_end = .;
    } > RAM AT > ROM

    __data_load = LOADADDR(.data);

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
    _end       = .;

    /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) }
}

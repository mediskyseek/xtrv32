/*============================================================================
 *  CoreMark port for MyXTRV32 (RV32I, multi-cycle core)
 *  Memory map
 *    0x0000_0000  ROM 64 KiB
 *    0x0001_0000  RAM 64 KiB
 *    0x0002_0000  UART TX
 *    0x0002_0100  GPIO (bit0 led_run, bit1 led_error)
 *    0x0002_0200  MTIME lo / hi  (100 MHz)
 *============================================================================*/
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>

/************************/
/* Data types and settings */
/************************/
#define HAS_FLOAT  0
#define HAS_TIME_H 0
#define USE_CLOCK  0
#define HAS_STDIO  0
#define HAS_PRINTF 0

#ifndef COMPILER_VERSION
#define COMPILER_VERSION "riscv-none-elf-gcc 15.2.0"
#endif
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS FLAGS_STR
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "STATIC"
#endif

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef ee_u32         ee_ptr_int;
typedef size_t         ee_size_t;

#define NULL ((void *)0)

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

/* 100 MHz free running timer, 32-bit window is enough for a 10 s run */
typedef ee_u32 CORE_TICKS;
#define CORETIMETYPE ee_u32
#define EE_TICKS_PER_SEC 100000000u

#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif
#ifndef MEM_METHOD
#define MEM_METHOD MEM_STATIC
#endif
#ifndef MULTITHREAD
#define MULTITHREAD     1
#define USE_PTHREAD     0
#define USE_FORK        0
#define USE_SOCKET      0
#endif
#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif
#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

int ee_printf(const char *fmt, ...);

#endif /* CORE_PORTME_H */

/*============================================================================
 *  CoreMark port for MyXTRV32
 *    - 100 MHz MTIME at 0x0002_0200
 *    - polled UART TX at 0x0002_0000
 *    - MEM_STATIC, no malloc, no interrupts
 *============================================================================*/
#include "coremark.h"

#define MTIME_LO  (*(volatile ee_u32 *)0x00020200u)
#define MTIME_HI  (*(volatile ee_u32 *)0x00020204u)
#define GPIO_LED  (*(volatile ee_u32 *)0x00020100u)

#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#elif VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#else
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif

volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

/*---------------------------------------------------------------- timing */
CORETIMETYPE
barebones_clock(void)
{
    /* 100 MHz counter; a 10 s run uses 1e9 ticks, well inside 32 bits */
    return (CORETIMETYPE)MTIME_LO;
}

static CORETIMETYPE start_time_val, stop_time_val;

void
start_time(void)
{
    start_time_val = barebones_clock();
}

void
stop_time(void)
{
    stop_time_val = barebones_clock();
}

CORE_TICKS
get_time(void)
{
    return (CORE_TICKS)(stop_time_val - start_time_val);
}

secs_ret
time_in_secs(CORE_TICKS ticks)
{
    return ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
}

/*---------------------------------------------------------------- seeds */
/* get_seed_32() is provided by core_util.c (SEED_VOLATILE path). */

/*---------------------------------------------------------------- init */
void
portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;

    GPIO_LED = 1; /* run LED on while the benchmark executes */

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
    {
        ee_printf("ERROR! ee_ptr_int cannot hold a pointer!\n");
    }
    if (sizeof(ee_u32) != 4)
    {
        ee_printf("ERROR! ee_u32 is not 32 bits!\n");
    }
    p->portable_id = 1;
}

void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
    GPIO_LED = 0;
}

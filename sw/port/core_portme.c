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

/*---------------------------------------------------------------- perf counters */
#define PERF_BASE  0x00020300u
#define PERF_INST  (*(volatile ee_u32 *)(PERF_BASE + 0x00u))
#define PERF_ALU   (*(volatile ee_u32 *)(PERF_BASE + 0x04u))
#define PERF_LOAD  (*(volatile ee_u32 *)(PERF_BASE + 0x08u))
#define PERF_STORE (*(volatile ee_u32 *)(PERF_BASE + 0x0Cu))
#define PERF_BR    (*(volatile ee_u32 *)(PERF_BASE + 0x10u))
#define PERF_MUL   (*(volatile ee_u32 *)(PERF_BASE + 0x14u))
#define PERF_DIV   (*(volatile ee_u32 *)(PERF_BASE + 0x18u))
#define PERF_BTAKEN (*(volatile ee_u32 *)(PERF_BASE + 0x1Cu))
#define PERF_BNOT   (*(volatile ee_u32 *)(PERF_BASE + 0x20u))
#define PERF_ST_LD  (*(volatile ee_u32 *)(PERF_BASE + 0x24u))
#define PERF_ST_BR  (*(volatile ee_u32 *)(PERF_BASE + 0x28u))
#define PERF_ST_MD  (*(volatile ee_u32 *)(PERF_BASE + 0x2Cu))
#define PERF_FLUSH  (*(volatile ee_u32 *)(PERF_BASE + 0x30u))

static ee_u32 s_inst, s_alu, s_load, s_store, s_br, s_mul, s_div;
static ee_u32 e_inst, e_alu, e_load, e_store, e_br, e_mul, e_div;
static ee_u32 s_btaken, s_bnot, s_stld, s_stbr, s_stmd, s_flush;
static ee_u32 e_btaken, e_bnot, e_stld, e_stbr, e_stmd, e_flush;
static ee_u32 run_cycles;

/* percentage helper (64-bit intermediate, avoids the 32-bit overflow that
   a plain "part * 100 / total" would hit for 1e9+ cycle counts) */
static unsigned long
pct_of(ee_u32 part, ee_u32 total)
{
    if (!total)
        return 0;
    return (unsigned long)(((unsigned long long)part * 100ull)
                           / (unsigned long long)total);
}

void
start_time(void)
{
    start_time_val = barebones_clock();
    s_inst  = PERF_INST;
    s_alu   = PERF_ALU;
    s_load  = PERF_LOAD;
    s_store = PERF_STORE;
    s_br    = PERF_BR;
    s_mul   = PERF_MUL;
    s_div   = PERF_DIV;
    s_btaken = PERF_BTAKEN;
    s_bnot   = PERF_BNOT;
    s_stld   = PERF_ST_LD;
    s_stbr   = PERF_ST_BR;
    s_stmd   = PERF_ST_MD;
    s_flush  = PERF_FLUSH;
}

void
stop_time(void)
{
    stop_time_val = barebones_clock();
    e_inst  = PERF_INST;
    e_alu   = PERF_ALU;
    e_load  = PERF_LOAD;
    e_store = PERF_STORE;
    e_br    = PERF_BR;
    e_mul   = PERF_MUL;
    e_div   = PERF_DIV;
    e_btaken = PERF_BTAKEN;
    e_bnot   = PERF_BNOT;
    e_stld   = PERF_ST_LD;
    e_stbr   = PERF_ST_BR;
    e_stmd   = PERF_ST_MD;
    e_flush  = PERF_FLUSH;
    run_cycles = stop_time_val - start_time_val;
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

    ee_printf("BOOT\r\n");

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

    /* ---- pipeline performance report (v0.4p, 4-stage) ----
       No fixed-cycle model any more: the counters below are direct hardware
       events, so CPI = cycles/instret and the extra cycles decompose into
       stalls + redirects + pipeline fill. */
    {
        ee_u32 inst  = e_inst  - s_inst;
        ee_u32 alu   = e_alu   - s_alu;
        ee_u32 load  = e_load  - s_load;
        ee_u32 store = e_store - s_store;
        ee_u32 br    = e_br    - s_br;
        ee_u32 mul   = e_mul   - s_mul;
        ee_u32 div   = e_div   - s_div;

        ee_u32 btaken = e_btaken - s_btaken;
        ee_u32 bnot   = e_bnot   - s_bnot;
        ee_u32 stld   = e_stld   - s_stld;
        ee_u32 stbr   = e_stbr   - s_stbr;
        ee_u32 stmd   = e_stmd   - s_stmd;
        ee_u32 flush  = e_flush  - s_flush;

        /* every stall cycle delays one retirement, every flush wastes one
           fetched slot: extra = cycles - instret should track these */
        ee_u32 stalls = stld + stbr + stmd;

        unsigned long long cpi100 =
            inst ? (((unsigned long long)run_cycles * 100ull) / (unsigned long long)inst)
                 : 0ull;

        ee_printf("[perf] cycles=%lu instret=%lu cpi_x100=%lu\n",
                  (unsigned long)run_cycles,
                  (unsigned long)inst,
                  (unsigned long)cpi100);
        ee_printf("[perf] inst alu=%lu load=%lu store=%lu br=%lu mul=%lu div=%lu\n",
                  (unsigned long)alu, (unsigned long)load, (unsigned long)store,
                  (unsigned long)br, (unsigned long)mul, (unsigned long)div);
        ee_printf("[perf] br taken=%lu not=%lu flush=%lu\n",
                  (unsigned long)btaken, (unsigned long)bnot, (unsigned long)flush);
        ee_printf("[perf] stall ld=%lu br=%lu md=%lu total=%lu (%lu%% of cycles)\n",
                  (unsigned long)stld, (unsigned long)stbr, (unsigned long)stmd,
                  (unsigned long)stalls,
                  pct_of(stalls, run_cycles));
        ee_printf("[perf] overhead cycles=%lu (instret+stall+flush=%lu)\n",
                  (unsigned long)(run_cycles - inst),
                  (unsigned long)(stalls + flush));
    }

    GPIO_LED = 0;
}

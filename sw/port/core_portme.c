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

static ee_u32 s_inst, s_alu, s_load, s_store, s_br, s_mul, s_div;
static ee_u32 e_inst, e_alu, e_load, e_store, e_br, e_mul, e_div;
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

    /* ---- pipeline-analysis report (cycles / instructions of the timed run) */
    {
        ee_u32 inst  = e_inst  - s_inst;
        ee_u32 alu   = e_alu   - s_alu;
        ee_u32 load  = e_load  - s_load;
        ee_u32 store = e_store - s_store;
        ee_u32 br    = e_br    - s_br;
        ee_u32 mul   = e_mul   - s_mul;
        ee_u32 div   = e_div   - s_div;

        /* cycles this core needs for each class (multi-cycle, no stalls) */
        ee_u32 model = alu * 4u + load * 5u + store * 5u + br * 4u
                       + mul * 5u + div * 37u;

        unsigned long long cpi100 =
            inst ? (((unsigned long long)run_cycles * 100ull) / (unsigned long long)inst)
                 : 0ull;

        ee_printf("[perf] cycles=%lu instret=%lu cpi_x100=%lu\n",
                  (unsigned long)run_cycles,
                  (unsigned long)inst,
                  (unsigned long)cpi100);
        ee_printf("[perf] alu=%lu load=%lu store=%lu br=%lu mul=%lu div=%lu\n",
                  (unsigned long)alu, (unsigned long)load, (unsigned long)store,
                  (unsigned long)br, (unsigned long)mul, (unsigned long)div);
        ee_printf("[perf] model_cycles=%lu actual=%lu gap=%lu\n",
                  (unsigned long)model,
                  (unsigned long)run_cycles,
                  (unsigned long)(run_cycles - model));
        ee_printf("[perf] share: alu=%lu%% load=%lu%% store=%lu%% br=%lu%% mul=%lu%% div=%lu%%\n",
                  pct_of(alu * 4u, run_cycles),
                  pct_of(load * 5u, run_cycles),
                  pct_of(store * 5u, run_cycles),
                  pct_of(br * 4u, run_cycles),
                  pct_of(mul * 5u, run_cycles),
                  pct_of(div * 37u, run_cycles));
    }

    GPIO_LED = 0;
}

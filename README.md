# MyXTRV32 v0.2

一个面向 xc7z020（Zynq-7020）的极简 RV32I 软核：**多周期 FSM、单发射、无流水线**，配套 BRAM ROM / BRAM RAM、UART TX 与 GPIO。v0.2 起支持 C 程序与 **CoreMark**，实机验证 CRC 全对。

```
RV32I  |  multi-cycle FSM  |  single issue  |  no pipeline
no CSR |  no interrupt      |  no cache      |  no MMU
ROM 64 KiB (BRAM)  |  RAM 64 KiB (BRAM)  |  UART TX 115200 8N1  |  2x LED
CoreMark 1.0 (6k performance run) validated on hardware
```

## 1. 特性

| 项目 | 说明 |
|------|------|
| ISA | RV32I 基础整数指令集（含 `LUI/AUIPC/JAL/JALR/BRANCH/LOAD/STORE/OP-IMM/OP/FENCE`） |
| 微架构 | 5 状态 FSM：`FETCH → DECODE → EXEC → MEM → WB`，单发射，无流水线 |
| CPI | ALU/分支/跳转 4 周期，load/store 5 周期 |
| 性能 | 100 MHz 下约 **25 MIPS**（理论值）；CoreMark 6k ≈ **3.1**（软件乘除） |
| CSR / 中断 / 异常 | 无（`ECALL/EBREAK` 作为停机指令，`FENCE` 作 NOP） |
| 乘除法 | 无 M 扩展，由 libgcc 软件模拟（`__mulsi3/__divsi3`…） |
| Cache / MMU | 无 |
| 指令总线 | 64 KiB BRAM ROM，同步读，1 拍延迟，独立数据读端口 |
| 数据总线 | 64 KiB BRAM RAM（字节写使能）+ MMIO |
| 外设 | UART TX（8N1）、2 位 LED、32 位自由计数器、64 位 mtime |
| 复位 | 内部上电复位（约 0.65 ms），无需外部复位引脚 |
| 顶层端口 | `clk`, `uart_tx`, `led_run`, `led_error` |

## 2. 目录结构

```
myxtrv32/
├── rtl/
│   ├── myxtrv32_core.v      # RV32I 多周期 FSM 核
│   ├── myxtrv32_top.v       # 顶层：POR、地址译码、UART/GPIO/MTIME 挂载
│   ├── myxtrv32_rom.v       # 指令 ROM —— 由脚本生成，勿手改
│   ├── myxtrv32_ram.v       # 64 KiB 数据 RAM
│   └── myxtrv32_uart_tx.v   # UART 发送器（8N1）
├── sw/
│   ├── crt0.S               # C 运行时启动（.data 拷贝 / .bss 清零 / call main）
│   ├── libc.c               # memcpy/memset/strlen 等最小实现
│   ├── uart.c               # UART 驱动 + ee_printf 的 uart_send_char
│   ├── link.ld              # ROM 0x0 / RAM 0x10000
│   ├── port/                # CoreMark 移植层（core_portme.[ch], ee_printf.c）
│   ├── coremark/            # CoreMark 官方源码（未修改）
│   ├── sim_test.S           # 仿真用短固件
│   └── build_coremark/      # 编译输出（elf/bin/dis）
├── constr/
│   └── myxtrv32.xdc         # 引脚与时钟约束
├── scripts/
│   ├── fetch_toolchain.py   # 下载 xPack RISC-V GCC 到 tools/
│   ├── build_sw.py          # 编译固件（--mode coremark|sim）+ 生成 ROM Verilog
│   ├── gen_rom.py           # bin -> myxtrv32_rom.v
│   ├── sim.py               # xsim 行为仿真
│   ├── build.tcl            # Vivado 综合/实现/生成 bit
│   └── build.py             # 一键调用（固件 + Vivado）
├── sim/
│   └── tb_myxtrv32.v        # 行为级 testbench（自带 UART 解码）
├── tools/                   # RISC-V GCC（已下载）
└── out/                     # bit / 报告输出
```

## 3. 内存映射

| 地址范围 | 大小 | 设备 | 说明 |
|----------|------|------|------|
| `0x0000_0000–0x0000_FFFF` | 64 KiB | ROM | 取指 + 常量读取（双读端口） |
| `0x0001_0000–0x0001_FFFF` | 64 KiB | RAM | 读写，字节/半字/字 |
| `0x0002_0000` | 4 B | UART TX | 写：发送一个字节 |
| `0x0002_0004` | 4 B | UART 状态 | 读：bit0 = busy |
| `0x0002_0100` | 4 B | GPIO | 写/读：bit0 = `led_run`，bit1 = `led_error` |
| `0x0002_0104` | 4 B | 计数器 | 读：32 位自由运行计数器 @100 MHz |
| `0x0002_0200` | 4 B | MTIME 低 | 读低 32 位，同时锁存高 32 位 |
| `0x0002_0204` | 4 B | MTIME 高 | 读锁存的高 32 位 |

栈顶 `0x0002_0000` 向下增长。

## 4. 快速开始

### 4.1 工具链（已完成）

```powershell
python scripts/fetch_toolchain.py          # 下载 xPack riscv-none-elf-gcc 15.2.0 到 tools/
tools/xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64/bin/riscv-none-elf-gcc.exe --version
```

### 4.2 编译固件

```powershell
python scripts/build_sw.py                  # CoreMark 镜像（默认）
#   -> sw/build_coremark/fw.elf, fw.bin, fw.dis
#   -> rtl/myxtrv32_rom.v

python scripts/build_sw.py --mode sim       # 仿真 smoke test 镜像
```

CoreMark 编译选项（脚本内固定）：`-march=rv32i -mabi=ilp32 -O2 -nostdlib`，
`-DPERFORMANCE_RUN=1 -DTOTAL_DATA_SIZE=6000 -DITERATIONS=0`，链接 `-lgcc`
（软件乘除）。

### 4.3 行为仿真（Vivado xsim）

```powershell
python scripts/sim.py
```

期望输出：

```
[TB] starting MyXTRV32 simulation
MyXTRV32 SIM OK
DONE
[TB] PASS: firmware printed the DONE line after 23 bytes
[TB] LED toggles = 3
```

### 4.4 综合 / 实现 / 生成 bit

```powershell
python scripts/build.py
#   -> out/myxtrv32_top.bit
#   -> out/timing_summary.rpt, utilization.rpt, power.rpt, drc.rpt
```

或直接用 Vivado（`build.tcl` 用的是单进程 in-memory 流程，不依赖 `launch_runs`
子进程，批处理下更稳）：

```powershell
D:\Xilinx\Vivado\2024.2\bin\vivado.bat -mode batch -source scripts/build.tcl
```

想用 GUI 看代码/波形时，可以先生成常规工程再打开 `vivado/myxtrv32/myxtrv32.xpr`：

```powershell
D:\Xilinx\Vivado\2024.2\bin\vivado.bat -mode batch -source scripts/create_project.tcl
```

### 4.5 下载到板子

Vivado Hardware Manager：`Open Target → Auto Connect → Program Device`，选择
`out/myxtrv32_top.bit`。

或命令行（板子已连 JTAG）：

```powershell
D:\Xilinx\Vivado\2024.2\bin\vivado.bat -mode batch -source scripts/program.tcl
```

### 4.6 上板现象

* **LED**：`led_run`（P18）每 0.5 s 翻转一次；`led_error`（N17）只在 CPU 停机或 RAM
  自检失败时点亮。
* **串口**：115200 8N1，TX 在扩展口 L14。上电后输出：

```
MyXTRV32 v0.1 -- RV32I multi-cycle soft core
ROM 16 KiB | RAM 32 KiB | UART 115200 8N1
LED blink + UART tick test running...

tick 0
tick 1
tick 2
...
```

## 5. 引脚约束

来自 `IO_ZYNQ7020.xlsx`：

| 信号 | 引脚 | 电平 |
|------|------|------|
| `clk`（100 MHz） | N18 (PL_CLK_MRCC) | LVCMOS33 |
| `uart_tx` | L14（扩展口） | LVCMOS33 |
| `led_run` | P18 | LVCMOS33 |
| `led_error` | N17 | LVCMOS33 |

> `uart_rx`（M15）本版未使用，核内无接收通路。
> Bank35 在该板上为可配置电压，默认按 3.3 V（`LVCMOS33`）约束；若实测该 bank 为
> 1.8 V，请把 xdc 里的 `LVCMOS33` 改为 `LVCMOS18`。

## 6. 设计说明

### 6.1 状态机

```
        ┌──────────────────────────────────────────┐
        │                                          │
        ▼                                          │
  ┌──────────┐   ┌──────────┐   ┌────────┐   ┌─────────┐
  │  FETCH   │──▶│  DECODE  │──▶│  EXEC  │──▶│   WB    │
  └──────────┘   └──────────┘   └────────┘   └─────────┘
                                     │             ▲
                                     ▼             │
                                ┌─────────┐        │
                                │   MEM   │────────┘
                                └─────────┘
```

* `FETCH`：`imem_addr = pc[13:2]`，ROM 同步读。
* `DECODE`：锁存指令，寄存器堆组合读取。
* `EXEC`：ALU / 分支判定 / 跳转目标 / 访存地址计算。
* `MEM`：仅 load/store 经过，发出 `dmem_req/we/addr/data/wstrb`。
* `WB`：写回寄存器并更新 `pc`。

存储器读延迟固定 1 拍，因此 `FETCH→DECODE` 与 `MEM→WB` 恰好对齐。

### 6.2 为什么 ROM 有第二个读端口

固件把字符串放在 `.rodata`（ROM 区），`lbu` 需要从数据端口读取常量。若 ROM 只有
取指端口，`lbu` 会读到 0（本版开发中实际踩到过这个坑）。因此 ROM 被综合为
简单双读端口 BRAM：`iaddr/idata` 供取指，`daddr/ddata` 供数据读。

### 6.3 地址译码

数据端口按 `addr[31:16]` 区分 ROM（`0x0000`）与 RAM（`0x0001`），MMIO 再按
`addr[31:8]` 细分 `0x0002_00`（UART）/`0x0002_01`（GPIO）/`0x0002_02`（MTIME）。
取指地址为 `pc[15:2]`（14 位，覆盖 64 KiB ROM）。

### 6.4 MTIME

`0x0002_0200` 是 64 位自由运行计数器（100 MHz）。读低 32 位时硬件顺便把高 32 位
锁存到 `mtime_hi_l`，随后读 `0x0002_0204` 得到一致的高位，避免进位撕裂。

## 7. 已知限制

* 仅支持自然对齐的 load/store；非对齐访问不会陷入，行为为部分写入/读出。
* 无 `M` 扩展：乘除法由 libgcc 软件模拟，CoreMark 分数因此偏低（见 8.5）。
* 无中断/异常/CSR/特权模式，`ECALL/EBREAK` 直接停机。
* 分支在 `EXEC` 判定、`WB` 更新 `pc`，因此每次跳转固定 4 周期，无延迟槽。
* 指令与数据共用同一 ROM 内容，不支持自修改代码。
* `clock()` 分辨率是 1 秒（`time_in_secs` 返回整数），CoreMark 打印的
  `Iterations/Sec` 与分数为整数截断。

## 8. 实测结果（xc7z020clg400-2，Vivado 2024.2）

### 8.1 资源占用

| 资源 | 用量 | 占比（xc7z020） |
|------|------|-----------------|
| LUT | 1662（core 573 / ROM 1011 / RAM 60） | 3.1% |
| FF | 582 | 0.55% |
| BRAM36 | 32（ROM 16 + RAM 16） | 22.9% |
| LUTRAM | 44（寄存器堆） | — |
| DSP | 0 | 0% |
| 功耗 | 0.191 W（vector-less） | — |

### 8.2 时序

```
Setup WNS = +1.145 ns   ->  Fmax ~ 113 MHz
Hold  WHS = +0.057 ns
```

100 MHz 时钟下有 1.1 ns 余量。

### 8.3 验证

| 项目 | 结果 |
|------|------|
| 行为级仿真（xsim，RTL + 自制 UART 解码 tb） | PASS（v0.1 基线；当前会话 xsim 环境异常，见下注） |
| 综合 | 0 error，ROM 16xRAMB36 / RAM 16xRAMB36 |
| 实现 + DRC | 0 error |
| 比特流 | `out/myxtrv32_top.bit`（约 960 KB） |

> ROM 说明：若把未用区留 0，Vivado 会把整块 ROM 折叠成常量逻辑。
> `gen_rom.py` 默认用 `--fill pattern` 给未用地址填上互不相同的标记值，使
> 16384x32 全部落到 BRAM（16 个 RAMB36）。若要省资源，可改为 `--fill zero`。

> 运行环境备注：本机在纯批处理会话里跑 `xsim -runall` 会报
> `Could not open file mapping object (2)` 后崩溃（Windows 共享内存/DLL 环境问题），
> 与设计无关；功能验证以实机为准。

### 8.4 上板记录（2026-11-04）

* JTAG：Digilent JTAG-SMT1 → `xc7z020` (idcode `23727093`)，`xsct` 下载
  （`scripts/program_xsct.tcl`）。
* v0.1：串口 banner + `tick` 每 0.5 s 递增，连续 8 分钟无丢字节。
* v0.2：CoreMark 6k performance run 跑通，CRC 与官方一致。

### 8.5 CoreMark 结果（v0.2，rv32i 软件乘除，100 MHz）

```
6k performance run parameters for coremark.
CoreMark Size    : 2000
Total ticks      : 1285332880
Total time (secs): 12
Iterations/Sec   : 3
Iterations       : 40
Compiler version : riscv-none-elf-gcc 15.2.0
Compiler flags   : -O2 rv32i
Memory location  : STATIC
seedcrc          : 0x8a02
[0]crclist       : 0xd4b0
[0]crcmatrix     : 0xbe52
[0]crcstate      : 0x5e47
[0]crcfinal      : 0xdd86
Correct operation validated.
```

| 指标 | 数值 |
|------|------|
| 运行时间 | 12.85 s（≥10 s，合法） |
| 迭代次数 | 40 |
| CoreMark 分数 | ≈ **3.11**（40 / 12.85 s） |
| CoreMark/MHz | ≈ **0.031** |
| 单次迭代周期 | 32.1 M 周期（40 迭代 / 1.285e9 周期） |

分数偏低的主因是 **乘除法走 libgcc 软件模拟**：CoreMark 的 CRC、链表和矩阵
运算里 32 位乘法密度很高，软件 `__mulsi3` 每次约 30–50 条指令。加 M 扩展
（第 3 步）预计能提升 3–5 倍。

## 9. 版本

* **v0.2** —— 扩展为可跑 C 程序与 CoreMark：ROM/RAM 各扩到 64 KiB、地址空间重划
  （ROM `0x0` / RAM `0x10000` / MMIO `0x20000`）、64 位 MTIME、`crt0.S` + 最小
  libc、CoreMark 移植层（`MEM_STATIC`、`ee_printf`、`clock()`）。实机 CoreMark
  CRC 全部通过（`0xd4b0` / `0xbe52` / `0x5e47`），分数 ≈3.11 @100 MHz。
  综合 WNS +1.145 ns，BRAM 32/140。
* **v0.1** —— 首个可上板版本：RV32I 多周期核 + 16 KiB ROM + 32 KiB RAM + UART TX +
  GPIO/LED。xsim 仿真通过，xc7z020clg400-2 综合实现通过（WNS +1.622 ns），
  比特流已生成并在实机（xc7z020 + COM12）验证：banner 正常、`tick` 递增、LED 闪烁。
  修复：`print_u32` 缺 NUL 终止导致多打印 `ra` 低字节；banner 多个 `.asciz` 导致只输出首行。

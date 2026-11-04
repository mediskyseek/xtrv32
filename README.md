# MyXTRV32

面向 xc7z020（Zynq-7020）的 RISC-V 软核。当前主线是 **v0.5：四级流水线 RV32IM**，
100 MHz 时序收敛，CoreMark 1.0 = **37.20**（CPI 1.256），CoreMark CRC 已在板上验证。

```
RV32IM |  4-stage pipeline (IF | ID/EX | MEM | WB)  |  single issue
no CSR |  no interrupt  |  no cache  |  no MMU  |  static not-taken
ROM 64 KiB (BRAM)  |  RAM 64 KiB (BRAM)  |  UART TX 115200 8N1  |  2x LED
```

## 1. 版本与实测性能

| 版本 | 微架构 | CPI | CoreMark | WNS | 备注 |
|---|---|---|---|---|---|
| v0.3 | 多周期 FSM | 4.27 | 10.93 | — | M 扩展，无流水线 |
| v0.4 | 四级流水线 | 1.315 | 35.53 | +0.044 | IF / ID·EX / MEM / WB |
| **v0.5** | 四级流水线 | **1.256** | **37.20** | **+0.036** | 冒险修复 + MUL 单拍 |

板上数据（600 iterations，`python scripts/bench_hw.py`）：

```
[perf] cycles=1612696209 instret=1284402099 cpi_x100=125
[perf] inst alu=672273828 load=229565989 store=49195949 br=257226333 mul=76140000 div=0
[perf] br taken=125647471 not=99875745 flush=157350588
[perf] stall ld=45832122 br=48971400 md=76140000 total=170943522 (10% of cycles)
```

资源：LUT 2339 / FF 661 / DSP 4 / BRAM 32（release 构建）。
详细分解与优化记录见 [doc/v0.5_hazards_and_mul.md](doc/v0.5_hazards_and_mul.md)。

## 2. 微架构

```
pc ──► ROM(同步输出即 IF/ID) ──► ID·EX 组合级 ──► EX/MEM ──► MEM/WB ──► WB
                                 译码/寄存器堆/前递/ALU/分支判定
```

| 机制 | 实现 |
|---|---|
| IF/ID | 不额外加指令寄存器，直接复用 ROM 的同步输出寄存器；只附加 `if_id_pc`/`if_id_valid` |
| EX/MEM | `alu_r`、`mem_addr`、`mem_wdata`、`mem_wstrb`、`rd`、`class`、`valid` |
| 存储器接口 | 地址/使能/写数据全部寄存后送 BRAM，保证端口只看到寄存器输出 |
| ALU→ALU | EX/MEM 前递，1 级 mux |
| LOAD→use | 停 1 拍后用 MEM/WB 前递（RAM 数据在 WB 拍有效）；只比较指令真正读取的源寄存器 |
| MUL | 停 1 拍，低 32 位由 DSP 直送 EX/MEM；`MULH/MULHSU/MULHU` 再等 1 拍取寄存后的 64 位积 |
| DIV | 32 次迭代，阻塞 ID/EX，EX/MEM 插气泡 |
| 分支/跳转 | 在 ID/EX 判定，同沿冲刷 IF/ID；静态预测不跳转，每次 redirect 固定 1 拍 |
| 乘法器保护 | load-use 冒泡期间禁止锁存操作数（否则前递拿到的是地址）；被冲刷的 MUL/DIV 不启动 |

## 3. 目录结构

```
rtl/myxtrv32_core_v4p.v   四级流水线核心（当前主线）
rtl/myxtrv32_top_v4.v     v0.5 顶层：PC/ROM/RAM/UART/GPIO/MTIME/PERF
rtl/myxtrv32_rom.v        由固件生成的 ROM 镜像（build_sw.py 产生，不入库）
rtl/myxtrv32_ram.v        64 KiB 数据 RAM
rtl/myxtrv32_uart_tx.v    UART TX
scripts/build.tcl         Vivado 非工程流程（综合+实现+bit）
scripts/build.py          一步构建（固件 + bit）
scripts/build_sw.py       编译固件并生成 ROM（--mode coremark|alu|mem|branch|muldiv|hazard|mulchain）
scripts/sim_v4.py         Icarus 定向回归（6 个 bench）
scripts/bench_hw.py       上板：下载 bit + 采集 UART + 解析 CoreMark/perf
sw/                       测试程序与 CoreMark 移植
doc/v0.5_hazards_and_mul.md   本次优化的分析与实测记录
doc/v0.4_pipeline_cycles.md   v0.4 逐周期设计（历史）
doc/v0.3_architecture.md      v0.3 多周期实现（历史归档）
release/v0.5/             发布快照（RTL、bit、时序/资源报告、运行日志）
```

`rtl/myxtrv32_core_v4.v` 是早期三级流水线**骨架**（只有 ALU 子集），无脚本引用；
`rtl/myxtrv32_core.v` / `myxtrv32_top.v` 是 v0.3 遗留，仅 `scripts/sim_iv.py` 使用。

## 4. 构建、仿真与上板

```bash
# 固件 + 综合/实现/bit（默认 v0.5）
python scripts/build.py

# 只重建固件与 ROM 镜像
python scripts/build_sw.py --mode coremark

# 带扩展性能计数器（CPI 分解）
python scripts/build_sw.py --perf
vivado -mode batch -source scripts/build.tcl -tclargs myxtrv32_top_v4 perf

# 定向仿真回归（Icarus Verilog）
python scripts/sim_v4.py --mode all

# 上板测量
python scripts/bench_hw.py --port COM12 --seconds 30 --tag run
```

v0.3 的 UART 级联仿（`scripts/sim_iv.py`）仍然保留，用于跑 `mtest`/`sim` 镜像。

## 5. 内存映射

| 区间 | 用途 |
|---|---|
| `0x0000_0000` | 64 KiB ROM（指令） |
| `0x0001_0000` | 64 KiB RAM（数据） |
| `0x0002_0000` | UART TX |
| `0x0002_0100` | GPIO（LED） |
| `0x0002_0200` | MTIME（64 位自由计数器） |
| `0x0002_0300` | PERF 计数器（只读，32 位/个） |

PERF 偏移：`0x00` instret、`0x04` alu、`0x08` load、`0x0C` store、`0x10` 分支/跳转、
`0x14` mul、`0x18` div、`0x1C` br_taken、`0x20` br_not、`0x24` stall_load_use、
`0x28` stall_br_dep、`0x2C` stall_muldiv、`0x30` flush。

## 6. 引脚（xc7z020clg400-2）

| 信号 | 引脚 | 说明 |
|---|---|---|
| clk | N18 | 100 MHz 单端输入，`create_clock -period 10.000` |
| uart_tx | L14 | 115200 8N1 |
| led_run | P18 | 运行指示 |
| led_error | N17 | 错误指示 |

## 7. 已知限制

- 无 CSR、无中断/异常，`ECALL/EBREAK` 作为停机指令，`FENCE` 视为 NOP
- 无 cache/MMU，取指与数据访问都是单周期同步 BRAM
- 分支为静态不跳转，每次 taken 固定 1 拍惩罚
- 性能计数器多路选择器与主数据通路共用 `dmem_rdata`，开启 `PERF_EXT` 会让 WNS 变成负值（-0.217 ns）

## 8. 历史版本

- [v0.4 逐周期设计](doc/v0.4_pipeline_cycles.md)
- [v0.3 多周期实现](doc/v0.3_architecture.md)

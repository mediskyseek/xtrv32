#!/usr/bin/env python3
"""Build a MyXTRV32 firmware image and regenerate the ROM Verilog.

  python scripts/build_sw.py                     # CoreMark image -> rtl/myxtrv32_rom.v
  python scripts/build_sw.py --mode sim          # simulation smoke test image
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SW = ROOT / "sw"
RTL = ROOT / "rtl"
TOOLS = ROOT / "tools"
TMPDIR = ROOT / "tmp"
COREMARK = SW / "coremark" / "coremark-main"
PORT = SW / "port"


def find_toolchain() -> Path:
    cands = sorted(TOOLS.glob("xpack-riscv-none-elf-gcc-*/bin"))
    for c in cands:
        if (c / "riscv-none-elf-gcc.exe").is_file() or (c / "riscv-none-elf-gcc").is_file():
            return c
    raise SystemExit(f"no RISC-V toolchain under {TOOLS} -- run scripts/fetch_toolchain.py first")


def exe(bindir: Path, name: str) -> str:
    p_win = bindir / (name + ".exe")
    return str(p_win) if p_win.is_file() else str(bindir / name)


def run(cmd: list[str], cwd: Path) -> None:
    print("+", " ".join(str(c) for c in cmd), flush=True)
    TMPDIR.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["TEMP"] = str(TMPDIR)
    env["TMP"] = str(TMPDIR)
    env["TMPDIR"] = str(TMPDIR)
    r = subprocess.run([str(c) for c in cmd], cwd=cwd, text=True,
                       capture_output=True, env=env)
    if r.stdout:
        print(r.stdout, end="")
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        raise SystemExit(f"command failed ({r.returncode})")


def coremark_sources() -> list[Path]:
    return [
        SW / "crt0.S",
        SW / "libc.c",
        SW / "uart.c",
        PORT / "core_portme.c",
        PORT / "ee_printf.c",
        COREMARK / "core_list_join.c",
        COREMARK / "core_main.c",
        COREMARK / "core_matrix.c",
        COREMARK / "core_state.c",
        COREMARK / "core_util.c",
    ]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["coremark", "sim", "mtest", "alu", "mem", "branch", "muldiv"], default="coremark")
    ap.add_argument("--build-dir", default=None)
    ap.add_argument("--rom-out", default="rtl/myxtrv32_rom.v")
    ap.add_argument("-O", dest="opt", default="O2", help="optimisation level (O2/O3/Os)")
    ap.add_argument("--perf", action="store_true", help="enable PERF_EXT extended counters")
    args = ap.parse_args()

    build = (ROOT / args.build_dir).resolve() if args.build_dir else (SW / f"build_{args.mode}").resolve()
    rom_out = (ROOT / args.rom_out).resolve()
    build.mkdir(parents=True, exist_ok=True)

    tc = find_toolchain()
    gcc = exe(tc, "riscv-none-elf-gcc")
    objcopy = exe(tc, "riscv-none-elf-objcopy")
    objdump = exe(tc, "riscv-none-elf-objdump")

    elf = build / "fw.elf"
    binf = build / "fw.bin"

    common = [
        "-march=rv32im", "-mabi=ilp32",
        "-nostdlib", "-ffreestanding", "-fno-builtin",
        f"-{args.opt}", "-g",
        "-ffunction-sections", "-fdata-sections",
        "-Wl,-T," + str(SW / "link.ld"),
        "-Wl,--gc-sections",
        "-Wl,--no-relax",
        "-Wl,--build-id=none",
    ]

    if args.mode == "coremark":
        sources = [str(p) for p in coremark_sources()]
        for p in sources:
            if not Path(p).is_file():
                raise SystemExit(f"missing source: {p}")
        extra = [
            "-DPERFORMANCE_RUN=1",
            "-DTOTAL_DATA_SIZE=6000",
            "-DITERATIONS=0",
            '-DFLAGS_STR="-O2 rv32im"',
            f"-I{COREMARK}",
            f"-I{PORT}",
        ]
        cmd = [gcc] + common + extra + ["-o", str(elf)] + sources + ["-lgcc"]
    elif args.mode == "alu":
        cmd = [gcc] + common + ["-o", str(elf), str(SW / "alu_test.S")]
    elif args.mode == "mem":
        cmd = [gcc] + common + ["-o", str(elf), str(SW / "mem_test.S")]
    elif args.mode == "branch":
        cmd = [gcc] + common + ["-o", str(elf), str(SW / "branch_test.S")]
    elif args.mode == "muldiv":
        cmd = [gcc] + common + ["-o", str(elf), str(SW / "muldiv_test.S")]
    elif args.mode == "mtest":
        sources = [str(SW / "crt0.S"), str(SW / "libc.c"), str(SW / "uart.c"), str(SW / "mtest.c")]
        for p in sources:
            if not Path(p).is_file():
                raise SystemExit(f"missing source: {p} (run scripts/gen_mtest.py first)")
        cmd = [gcc] + common + ["-o", str(elf)] + sources + ["-lgcc"]
    else:
        cmd = [gcc] + common + ["-o", str(elf), str(SW / "sim_test.S")]

    if args.perf:
        cmd.insert(cmd.index("-o"), "-DPERF_EXT")

    run(cmd, cwd=SW)
    run([objcopy, "-O", "binary", str(elf), str(binf)], cwd=build)

    r = subprocess.run([objdump, "-d", "-M", "no-aliases", str(elf)],
                       text=True, capture_output=True)
    (build / "fw.dis").write_text(r.stdout, encoding="utf-8")

    run([sys.executable, str(ROOT / "scripts" / "gen_rom.py"),
         str(binf), str(rom_out)], cwd=ROOT)

    size = binf.stat().st_size
    print(f"[build_sw] {args.mode}: fw.bin = {size} bytes ({size / 4:.0f} words)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

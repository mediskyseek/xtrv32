#!/usr/bin/env python3
"""Run the behavioural simulation with the Vivado simulator (xsim).

Builds the simulation firmware, then calls xvlog / xelab / xsim.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
SIM = ROOT / "sim"
WORK = SIM / "work"

VIVADO_CANDIDATES = [
    Path(r"D:\Xilinx\Vivado\2024.2\bin"),
    Path(r"D:\Xilinx\Vivado\2018.3\bin"),
]


def find_vivado_bin() -> Path:
    for c in VIVADO_CANDIDATES:
        if (c / "xvlog.bat").is_file():
            return c
    raise SystemExit("Vivado simulator not found")


def run(cmd: str, cwd: Path, env: dict) -> int:
    print("+", cmd, flush=True)
    r = subprocess.run(cmd, cwd=cwd, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(r.stdout, end="")
    return r.returncode


def main() -> int:
    vbin = find_vivado_bin()
    tmpdir = ROOT / "tmp"
    tmpdir.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["PATH"] = str(vbin) + os.pathsep + env.get("PATH", "")
    # the system %TEMP% is not always writable from this session, and xsim
    # needs it for its shared-memory segments
    env["TEMP"] = str(tmpdir)
    env["TMP"] = str(tmpdir)
    env["TMPDIR"] = str(tmpdir)

    # 1. simulation firmware + ROM model
    r = subprocess.run([sys.executable, str(ROOT / "scripts" / "build_sw.py"),
                        "--mode", "sim",
                        "--build-dir", "sw/build_sim",
                        "--rom-out", "rtl/myxtrv32_rom_sim.v"],
                       cwd=ROOT)
    if r.returncode != 0:
        return r.returncode

    # 2. clean work dir
    if WORK.exists():
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True)

    srcs = [
        RTL / "myxtrv32_core.v",
        RTL / "myxtrv32_uart_tx.v",
        RTL / "myxtrv32_ram.v",
        RTL / "myxtrv32_rom_sim.v",     # sim image replaces the production ROM
        RTL / "myxtrv32_top.v",
        SIM / "tb_myxtrv32.v",
    ]
    for s in srcs:
        if not s.is_file():
            raise SystemExit(f"missing source: {s}")

    log = "xvlog.log"
    cmd = " ".join([f'"{vbin / "xvlog.bat"}"', "-sv", "-log", log] + [f'"{s}"' for s in srcs])
    if run(cmd, WORK, env) != 0:
        return 1

    if run(f'"{vbin / "xelab.bat"}" -debug typical -relax -log xelab.log -snapshot tb_sim tb_myxtrv32', WORK, env) != 0:
        return 1

    if run(f'"{vbin / "xsim.bat"}" tb_sim -runall -log xsim.log', WORK, env) != 0:
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())

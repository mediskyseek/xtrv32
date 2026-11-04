#!/usr/bin/env python3
"""Behavioural simulation with Icarus Verilog.

This is the primary simulation path for this repo -- Vivado's xsim fails in
this environment with 'Could not open file mapping object (2)'.

  python scripts/sim_iv.py                 # sim_test firmware (fast smoke test)
  python scripts/sim_iv.py --mode mtest    # M-extension self test
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
SIM = ROOT / "sim"
WORK = SIM / "iv"
IV = Path(r"C:\iverilog\bin")


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess:
    print("+", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run([str(c) for c in cmd], cwd=cwd, text=True,
                          capture_output=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["sim", "mtest", "coremark"], default="sim")
    args = ap.parse_args()

    if not (IV / "iverilog.exe").is_file():
        raise SystemExit(f"iverilog not found under {IV}")

    # 1. firmware + ROM model for the requested image
    r = subprocess.run([sys.executable, str(ROOT / "scripts" / "build_sw.py"),
                        "--mode", args.mode,
                        "--build-dir", f"sw/build_{args.mode}",
                        "--rom-out", "rtl/myxtrv32_rom_sim.v"],
                       cwd=ROOT)
    if r.returncode != 0:
        return r.returncode

    WORK.mkdir(parents=True, exist_ok=True)

    srcs = [
        RTL / "myxtrv32_core.v",
        RTL / "myxtrv32_uart_tx.v",
        RTL / "myxtrv32_ram.v",
        RTL / "myxtrv32_rom_sim.v",     # simulation image, not the production ROM
        RTL / "myxtrv32_top.v",
        SIM / "tb_myxtrv32.v",
    ]
    for s in srcs:
        if not s.is_file():
            raise SystemExit(f"missing source: {s}")

    vvp = WORK / "sim.vvp"
    r = run([str(IV / "iverilog.exe"), "-g2012", "-o", str(vvp),
             "-s", "tb_myxtrv32"] + [str(s) for s in srcs], ROOT)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr, file=sys.stderr)
        return 1

    r = run([str(IV / "vvp.exe"), str(vvp)], ROOT)
    print(r.stdout)
    if r.stderr:
        print(r.stderr, file=sys.stderr)

    ok = "PASS" in r.stdout or "PASS" in r.stderr
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

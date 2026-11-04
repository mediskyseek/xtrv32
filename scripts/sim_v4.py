#!/usr/bin/env python3
"""Directed regression for the four-stage core (rtl/myxtrv32_core_v4p.v).

Unlike sim_iv.py (which drives the v0.3 top level), this bench-level flow
compiles a small directed testbench together with the core, the ROM model and
(where needed) the data RAM.

  python scripts/sim_v4.py                 # run every mode
  python scripts/sim_v4.py --mode muldiv   # one bench
  python scripts/sim_v4.py --mode hazard --skip-sw   # reuse the built image

Each mode maps to sw/<mode>_test.S and sim/tb_v4_<mode>.v.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
SIM = ROOT / "sim"
WORK = SIM / "iv"
IV = Path(r"C:\iverilog\bin")

MODES = ["alu", "mem", "branch", "muldiv", "hazard", "mulchain"]

NEEDS_RAM = {"mem", "hazard"}


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess:
    print("+", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run([str(c) for c in cmd], cwd=cwd, text=True,
                          capture_output=True)


def sim_one(mode: str, skip_sw: bool) -> tuple[bool, str]:
    tb = f"tb_v4_{mode}"

    if not skip_sw:
        r = subprocess.run([sys.executable, str(ROOT / "scripts" / "build_sw.py"),
                            "--mode", mode,
                            "--build-dir", f"sw/build_{mode}",
                            "--rom-out", "rtl/myxtrv32_rom_sim.v"],
                           cwd=ROOT)
        if r.returncode != 0:
            return False, f"{mode}: firmware build failed"

    srcs = [RTL / "myxtrv32_core_v4p.v"]
    if mode in NEEDS_RAM:
        srcs.append(RTL / "myxtrv32_ram.v")
    srcs += [RTL / "myxtrv32_rom_sim.v", SIM / f"{tb}.v"]
    for s in srcs:
        if not s.is_file():
            return False, f"{mode}: missing source {s}"

    WORK.mkdir(parents=True, exist_ok=True)
    vvp = WORK / f"f_{mode}.vvp"
    r = run([str(IV / "iverilog.exe"), "-g2012", "-o", str(vvp),
             "-s", tb] + [str(s) for s in srcs], ROOT)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr, file=sys.stderr)
        return False, f"{mode}: compile failed"

    r = run([str(IV / "vvp.exe"), str(vvp)], ROOT)
    out = (r.stdout or "") + (r.stderr or "")
    ok = (r.returncode == 0) and ("[TB] PASS" in out)
    tail = [ln for ln in out.splitlines() if ln.startswith("[TB]")]
    return ok, f"{mode}: vvp exit={r.returncode} " + ("PASS" if ok else "FAIL") + \
        (" | " + " ; ".join(tail) if tail else "")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=MODES + ["all"], default="all")
    ap.add_argument("--skip-sw", action="store_true")
    args = ap.parse_args()

    if not (IV / "iverilog.exe").is_file():
        raise SystemExit(f"iverilog not found under {IV}")

    modes = MODES if args.mode == "all" else [args.mode]
    failures = 0
    for m in modes:
        ok, msg = sim_one(m, args.skip_sw)
        print(f"[sim_v4] {msg}", flush=True)
        if not ok:
            failures += 1

    print(f"[sim_v4] {len(modes) - failures}/{len(modes)} benches passed")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

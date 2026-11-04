#!/usr/bin/env python3
"""Program the board and capture the CoreMark UART output.

  python scripts/bench_hw.py --port COM12 --seconds 25

Prints the parsed CoreMark line plus the [perf] breakdown, and writes the raw
capture to out/uart_<tag>.txt.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XSCT = Path(r"D:\Xilinx\Vitis\2024.2\bin\xsct.bat")
TCL = ROOT / "scripts" / "program_bit.tcl"
CAP = ROOT / "scripts" / "capture_uart.ps1"


def parse(text: str) -> dict:
    out: dict[str, str] = {}
    m = re.search(r"Iterations\s*:\s*(\d+)", text)
    if m:
        out["iterations"] = m.group(1)
    m = re.search(r"Total ticks\s*:\s*(\d+)", text)
    if m:
        out["ticks"] = m.group(1)
    m = re.search(r"Iterations/Sec\s*:\s*(\d+)", text)
    if m:
        out["iter_per_sec"] = m.group(1)
    m = re.search(r"CoreMark 1\.0\s*:\s*([\d.]+)", text)
    if m:
        out["coremark"] = m.group(1)
    for name in ("crclist", "crcmatrix", "crcstate", "crcfinal"):
        m = re.search(name + r"\s*:\s*(0x[0-9a-fA-F]+)", text)
        if m:
            out[name] = m.group(1)
    m = re.search(r"\[perf\] cycles=(\d+) instret=(\d+) cpi_x100=(\d+)", text)
    if m:
        out["cycles"] = m.group(1)
        out["instret"] = m.group(2)
        out["cpi_x100"] = m.group(3)
    for line in text.splitlines():
        if line.startswith("[perf]"):
            out.setdefault("perf_lines", "")
            out["perf_lines"] += line + "\n"
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bit", default="out/myxtrv32_top_v4.bit")
    ap.add_argument("--port", default="COM12")
    ap.add_argument("--seconds", type=int, default=25)
    ap.add_argument("--tag", default="run")
    args = ap.parse_args()

    bit = (ROOT / args.bit).resolve()
    if not bit.is_file():
        raise SystemExit(f"missing bitstream: {bit}")

    raw = ROOT / "out" / f"uart_{args.tag}.txt"

    # start listening first so the boot banner is not lost
    cap = subprocess.Popen(
        ["pwsh", "-NoLogo", "-NoProfile", "-File", str(CAP),
         "-Port", args.port, "-Seconds", str(args.seconds + 5), "-Out", str(raw)],
        cwd=ROOT, stdout=subprocess.PIPE, text=True)

    subprocess.run([str(XSCT), str(TCL), str(bit)], cwd=ROOT,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"[bench_hw] programmed {bit.name}, capturing {args.port} ...", flush=True)

    cap.wait()
    print(cap.stdout or "", flush=True)

    text = raw.read_text(encoding="utf-8", errors="replace")
    info = parse(text)
    for k, v in info.items():
        if k == "perf_lines":
            continue
        print(f"[bench_hw] {k:12s} = {v}")
    if "perf_lines" in info:
        print(info["perf_lines"])
    if not info:
        print("[bench_hw] no CoreMark output parsed")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

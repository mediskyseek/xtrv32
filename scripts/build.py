#!/usr/bin/env python3
"""Run the full Vivado build (synthesis + implementation + bitstream).

  python scripts/build.py            # full flow
  python scripts/build.py --sw-only  # only rebuild the firmware/ROM
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIVADO = Path(r"D:\Xilinx\Vivado\2024.2\bin\vivado.bat")


def main() -> int:
    if "--sw-only" in sys.argv:
        return subprocess.run([sys.executable, str(ROOT / "scripts" / "build_sw.py")]).returncode

    # firmware first so the ROM model is up to date
    r = subprocess.run([sys.executable, str(ROOT / "scripts" / "build_sw.py")])
    if r.returncode != 0:
        return r.returncode

    if not VIVADO.is_file():
        raise SystemExit(f"Vivado not found at {VIVADO}")

    log = ROOT / "out" / "vivado_build.log"
    log.parent.mkdir(exist_ok=True)

    # -tclargs must come last: Vivado treats everything after it as user argv.
    cmd = [str(VIVADO), "-mode", "batch",
           "-source", str(ROOT / "scripts" / "build.tcl"),
           "-log", str(log),
           "-nojournal",
           "-tclargs", "myxtrv32_top_v4"]
    print("+", " ".join(cmd), flush=True)
    return subprocess.run(cmd, cwd=ROOT).returncode


if __name__ == "__main__":
    sys.exit(main())

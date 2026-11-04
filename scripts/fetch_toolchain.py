#!/usr/bin/env python3
"""Download + unpack the xPack RISC-V bare-metal GCC toolchain into tools/.

Usage:  python scripts/fetch_toolchain.py [--version v15.2.0-1]

The archive is ~465 MB; the script resumes partial downloads and verifies
the published SHA-256 before unpacking.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
BASE = "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download"


def log(msg: str) -> None:
    print(f"[fetch] {msg}", flush=True)


def http_get(url: str, dest: Path, retries: int = 5) -> Path:
    """Download url -> dest with resume + retry."""
    for attempt in range(1, retries + 1):
        have = dest.stat().st_size if dest.exists() else 0
        headers = {"User-Agent": "myxtrv32-fetch/1.0"}
        if have:
            headers["Range"] = f"bytes={have}-"
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                total = resp.headers.get("Content-Length")
                total = int(total) + have if total else None
                mode = "ab" if have and resp.status == 206 else "wb"
                if mode == "wb":
                    have = 0
                done = have
                t0 = time.time()
                with open(dest, mode) as fh:
                    while True:
                        chunk = resp.read(1 << 20)
                        if not chunk:
                            break
                        fh.write(chunk)
                        done += len(chunk)
                        if total and done % (32 << 20) < (1 << 20):
                            pct = 100.0 * done / total
                            spd = done / max(time.time() - t0, 1e-6) / 1e6
                            log(f"{done/1e6:8.1f}/{total/1e6:.1f} MB  {pct:5.1f}%  {spd:5.1f} MB/s")
            if total is None or dest.stat().st_size >= total:
                return dest
            log(f"short read ({dest.stat().st_size}/{total}), retrying")
        except Exception as exc:  # noqa: BLE001
            log(f"attempt {attempt} failed: {type(exc).__name__}: {exc}")
            time.sleep(3 * attempt)
    raise RuntimeError(f"could not download {url}")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="v15.2.0-1")
    ap.add_argument("--skip-verify", action="store_true")
    args = ap.parse_args()

    TOOLS.mkdir(parents=True, exist_ok=True)
    ver = args.version
    name = f"xpack-riscv-none-elf-gcc-{ver.lstrip('v')}-win32-x64"
    zip_path = TOOLS / f"{name}.zip"
    url = f"{BASE}/{ver}/{zip_path.name}"

    log(f"target: {zip_path}")
    if not (zip_path.exists() and zip_path.stat().st_size > 100 << 20):
        http_get(url, zip_path)
    log(f"archive size: {zip_path.stat().st_size/1e6:.1f} MB")

    if not args.skip_verify:
        sha_path = TOOLS / (zip_path.name + ".sha")
        try:
            http_get(url + ".sha", sha_path)
            expected = sha_path.read_text(encoding="utf-8").split()[0].strip()
            log(f"verifying sha256 ...")
            got = sha256(zip_path)
            if got.lower() != expected.lower():
                raise RuntimeError(f"sha mismatch: {got} != {expected}")
            log("sha256 OK")
        except Exception as exc:  # noqa: BLE001
            log(f"WARNING: sha verification skipped ({exc})")

    dest = TOOLS / name
    if not (dest / "bin").is_dir():
        log("unpacking (this takes a while) ...")
        tmp = TOOLS / f"_{name}_unpack"
        if tmp.exists():
            shutil.rmtree(tmp)
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(tmp)
        # the archive root is not always named after the zip; locate bin/
        gcc_hits = list(tmp.rglob("riscv-none-elf-gcc.exe"))
        src = gcc_hits[0].parent.parent if gcc_hits else (tmp / name)
        if dest.exists():
            shutil.rmtree(dest)
        shutil.move(str(src), str(dest))
        if tmp.exists():
            shutil.rmtree(tmp, ignore_errors=True)
    log(f"toolchain ready: {dest / 'bin'}")

    gcc = dest / "bin" / "riscv-none-elf-gcc.exe"
    if gcc.is_file():
        out = subprocess.run([str(gcc), "--version"], capture_output=True, text=True)
        log(out.stdout.splitlines()[0] if out.stdout else "gcc probe failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

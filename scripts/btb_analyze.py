#!/usr/bin/env python3
"""BTB / RAS feasibility analysis over a branch trace from tb_v4_trace.

  python scripts/btb_analyze.py out/branch_trace.txt

Trace line (7 columns):
    cycle  pc  type  taken  target  rd  rs1      (type 0=cond, 1=jal, 2=jalr)
or the older 4-column form without cycle/rd/rs1.

Baseline (v0.5): static not-taken, resolved in ID/EX.  Every taken conditional
branch and every JAL/JALR costs exactly one fetch bubble (`flush` counter).
A predictor pays off only when it says "taken" and the target is right:

  pred taken + taken + target ok  -> save 1 cycle
  pred taken + not taken          -> lose 1 cycle (baseline had no bubble)
  pred taken + taken + wrong tgt  -> 0 (still one bubble)

Projection is calibrated against the measured 600-iteration run, so the trace
length does not matter, only the redirect mix.
"""
from __future__ import annotations

import argparse
import collections
from pathlib import Path

# measured on hardware, 600 iterations (release build, v0.5)
CYC_TOTAL = 1_612_696_209
INST_TOTAL = 1_284_402_099
FLUSH_TOTAL = 157_350_588
CM_V05 = 37.20

COND, JAL, JALR = 0, 1, 2
LINK_REGS = (1, 5)


def load(path: Path):
    rows = []
    with path.open() as f:
        for line in f:
            p = line.split()
            if len(p) == 7:
                rows.append((int(p[0]), int(p[1], 16), int(p[2]), int(p[3]),
                             int(p[4], 16), int(p[5]), int(p[6])))
            elif len(p) == 4:
                rows.append((0, int(p[0], 16), int(p[1]), int(p[2]),
                             int(p[3], 16), 0, 0))
    return rows


def trim_idle(rows):
    i = len(rows) - 1
    while i > 0 and not (rows[i][2] == JAL and rows[i][4] == rows[i][1]):
        i -= 1
    if i == 0:
        return rows
    while i > 0 and rows[i][2] == JAL and rows[i][4] == rows[i][1]:
        i -= 1
    return rows[: i + 1]


class BTB:
    __slots__ = ("sets", "ways", "maxctr", "bits", "t")

    def __init__(self, n, ctr_max, ways=1):
        self.sets = n // ways
        self.ways = ways
        self.maxctr = ctr_max
        self.bits = max(1, self.sets.bit_length() - 1)
        self.t = [[None] * ways for _ in range(self.sets)]

    def predict(self, pc):
        s = self.t[(pc >> 2) & (self.sets - 1)]
        tag = pc >> (2 + self.bits)
        for w in range(self.ways):
            e = s[w]
            if e is not None and e[0] == tag:
                return True, e[1], w
        return False, None, None

    def update(self, pc, taken, target):
        s = self.t[(pc >> 2) & (self.sets - 1)]
        tag = pc >> (2 + self.bits)
        w = None
        for i in range(self.ways):
            if s[i] is not None and s[i][0] == tag:
                w = i
                break
        if w is None:
            if not taken:
                return
            for i in range(self.ways):
                if s[i] is None:
                    s[i] = [tag, target, 0]
                    w = i
                    break
            if w is None:
                w = self.ways - 1
                s[w] = [tag, target, 0]
        e = s[w]
        if taken:
            e[1] = target
            e[2] = min(self.maxctr, e[2] + 1)
        else:
            e[2] = max(0, e[2] - 1)


def run(rows, n=None, ctr=3, ras_depth=0):
    btb = BTB(n, ctr) if n else None
    ras = []
    save = lose = 0
    per = collections.Counter()
    for _cyc, pc, typ, taken, target, rd, rs1 in rows:
        is_ret = (typ == JALR and ras_depth and rd == 0 and rs1 in LINK_REGS)
        if is_ret and ras:
            pred = ras[-1]
            hit = True
            hit_tag = pred
        elif btb is not None:
            hit, hit_tag, _w = btb.predict(pc)
        else:
            hit, hit_tag = False, None

        pred_taken = hit
        if pred_taken and taken and hit_tag == target:
            save += 1
            per[(typ, "save")] += 1
        elif pred_taken and taken:
            per[(typ, "wrong_tgt")] += 1
        elif pred_taken and not taken:
            lose += 1
            per[(typ, "wrong_dir")] += 1
        elif taken:
            per[(typ, "miss")] += 1
        else:
            per[(typ, "ok_not")] += 1

        # ---- updates
        if ras_depth and typ in (JAL, JALR) and rd in LINK_REGS and not is_ret:
            ras.append(pc + 4)
            if len(ras) > ras_depth:
                ras.pop(0)
        if is_ret and ras:
            ras.pop()
        if btb is not None and not is_ret:
            btb.update(pc, bool(taken), target)
    return dict(save=save, lose=lose, net=save - lose, per=per)


def project(net, redirects):
    pct = net / max(1, redirects)
    saved = int(FLUSH_TOTAL * pct)
    cpi = (CYC_TOTAL - saved) / INST_TOTAL
    cm = 600.0 / ((CYC_TOTAL - saved) / 1e8)
    return pct, saved, cpi, cm, 100.0 * CM_V05 / cm


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("trace", nargs="?", default="out/branch_trace.txt")
    args = ap.parse_args()

    rows = load(Path(args.trace))
    if not rows:
        raise SystemExit("empty trace")
    rows = trim_idle(rows)

    n_cond = sum(1 for r in rows if r[2] == COND)
    n_jal = sum(1 for r in rows if r[2] == JAL)
    n_jalr = sum(1 for r in rows if r[2] == JALR)
    n_tk = sum(1 for r in rows if r[2] == COND and r[3])
    redirects = n_tk + n_jal + n_jalr
    span = rows[-1][0] - rows[0][0]

    print(f"trace          : {len(rows)} branches over {span} cycles "
          f"({span / max(1, CYC_TOTAL / 600):.2f} iterations)")
    print(f"  cond         : {n_cond}  (taken {n_tk}, "
          f"{100.0 * n_tk / max(1, n_cond):.1f}%)")
    print(f"  jal / jalr   : {n_jal} / {n_jalr}")
    print(f"  redirects    : {redirects}")
    print()

    # ---- stationarity: net gain per 1M-cycle window with a 64-entry BTB
    if span > 0:
        w = 1_000_000
        bins = collections.defaultdict(lambda: [0, 0])
        for _c, pc, typ, taken, target, rd, rs1 in rows:
            pass
        btb = BTB(64, 3)
        per_bin = collections.defaultdict(lambda: [0, 0])
        for cyc, pc, typ, taken, target, rd, rs1 in rows:
            hit, tgt, _ = btb.predict(pc)
            key = (cyc - rows[0][0]) // w
            if hit and taken and tgt == target:
                per_bin[key][0] += 1
            elif hit and not taken:
                per_bin[key][1] += 1
            btb.update(pc, bool(taken), target)
        print("per-1M-cycle window (64-entry BTB, net cycles):")
        for k in sorted(per_bin):
            s, l = per_bin[k]
            print(f"  win {k:>2}: save {s:>6} lose {l:>5} net {s - l:>6}")
        print()

    hdr = f"{'config':>22} {'save':>8} {'lose':>6} {'net':>8} {'net%':>6} " \
          f"{'CPI':>6} {'CM':>6} {'f_min':>6}"
    print(hdr)
    print("-" * len(hdr))

    best = None
    cfgs = []
    for n in (16, 32, 64, 128, 256):
        cfgs.append((f"BTB {n} 1w 2bit", dict(n=n, ctr=3)))
    cfgs.append(("RAS8 only", dict(n=None, ras_depth=8)))
    for n in (16, 32, 64):
        cfgs.append((f"BTB {n} + RAS8", dict(n=n, ctr=3, ras_depth=8)))

    for name, kw in cfgs:
        r = run(rows, **kw)
        pct, saved, cpi, cm, fmin = project(r["net"], redirects)
        print(f"{name:>22} {r['save']:>8} {r['lose']:>6} {r['net']:>8} "
              f"{100.0 * pct:>5.1f}% {cpi:>6.3f} {cm:>6.2f} {fmin:>6.1f}")
        if best is None or r["net"] > best[0]:
            best = (r["net"], name, r)

    net, name, r = best
    pct, saved, cpi, cm, fmin = project(net, redirects)
    print()
    print(f"best: {name} -> net {net} ({100.0 * pct:.1f}% of redirects)")
    print(f"  projected: saves {saved / 1e6:.1f}M cycles, CPI {cpi:.3f}, "
          f"CoreMark {cm:.2f}")
    print(f"  break-even Fmax: {fmin:.1f} MHz")
    for typ, nm in ((COND, "cond"), (JAL, "jal"), (JALR, "jalr")):
        print(f"  {nm:5s}: save {r['per'][(typ, 'save')]:7d}  "
              f"miss {r['per'][(typ, 'miss')]:7d}  "
              f"wrong_dir {r['per'][(typ, 'wrong_dir')]:7d}  "
              f"wrong_tgt {r['per'][(typ, 'wrong_tgt')]:5d}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

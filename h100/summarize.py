#!/usr/bin/env python3
"""Per-scenario means from dcgmi dmon output, in manifest order.

Usage: python summarize.py <run-dir>
"""
import csv
import pathlib
import statistics
import sys

COLS = ["GPUTL", "GRACT", "SMACT", "SMOCC", "TENSO", "DRAMA", "POWER"]
TRIM = 45  # seconds dropped at each end of every window


def parse(path):
    rows = []
    for line in path.read_text().splitlines():
        t = line.split()
        if len(t) != 2 + len(COLS) or t[0] != "GPU":
            continue
        rows.append([None if v == "N/A" else float(v) for v in t[2:]])
    return rows


def mean(rows, i):
    vals = [r[i] for r in rows if r[i] is not None]
    return statistics.fmean(vals) if vals else None


def fmt_pct(col, value):
    if value is None:
        return "N/A"
    # dmon prints GPUTL as a percent and profiling fields as 0-1 ratios
    return f"{value:.1f}" if col == "GPUTL" else f"{value * 100:.1f}"


run = pathlib.Path(sys.argv[1])
with open(run / "manifest.tsv", newline="") as fh:
    scenarios = [row["scenario"] for row in csv.DictReader(fh, delimiter="\t")]

print("| Scenario | Samples kept | GPUTL % | GRACT % | SMACT % | SMOCC % | TENSO % | DRAMA % | Power W | GPUTL / SMACT |")
print("|---|---|---|---|---|---|---|---|---|---|")
for name in scenarios:
    rows = parse(run / f"{name}.dcgm")
    kept = rows[TRIM:-TRIM] if len(rows) > 2 * TRIM + 10 else rows
    m = {c: mean(kept, i) for i, c in enumerate(COLS)}
    ratio = "N/A"
    if m["GPUTL"] is not None and m["SMACT"]:
        ratio = f"{m['GPUTL'] / (m['SMACT'] * 100):.1f}x"
    power = "N/A" if m["POWER"] is None else f"{m['POWER']:.0f}"
    cells = [fmt_pct(c, m[c]) for c in ["GPUTL", "GRACT", "SMACT", "SMOCC", "TENSO", "DRAMA"]]
    print(f"| {name} | {len(kept)} | " + " | ".join(cells) + f" | {power} | {ratio} |")

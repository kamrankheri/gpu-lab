#!/usr/bin/env python3
"""Post-hoc measures for the H100 run. Not part of the registered analysis.

The registered analysis is summarize.py and its output, summary.md. Everything
this script prints was decided after the run and is labeled post-hoc wherever it
is published (DEVIATIONS.md notes 7 and 8).

Usage: python posthoc.py <run-dir>

vLLM load scenarios, one method for all six windows (rate_0.2, rate_2 and saturated, in each of two repeats):
  load start   first sample with GPUTL above 0, ignoring any leading busy samples
               before the window's first idle sample (dmon's first sample of a
               window can carry the previous scenario's load)
  load means   samples from load start through the end of the window minus 45 s
  request rate completed requests (last progress line in the .stdout) divided by
               seconds from load start to the end of the window
Training: tokens per second and token slots per second from the JSON line in the
.stdout, where slots = steps x batch size x sequence length.
"""
import json
import pathlib
import re
import statistics
import sys

COLS = ["GPUTL", "GRACT", "SMACT", "SMOCC", "TENSO", "DRAMA", "POWER"]
TRIM = 45  # same end trim as summarize.py
WINDOW = 600  # registered length of every vLLM load and training window, seconds


def parse(path):
    rows = []
    for line in path.read_text().splitlines():
        t = line.split()
        if len(t) != 2 + len(COLS) or t[0] != "GPU":
            continue
        rows.append([None if v == "N/A" else float(v) for v in t[2:]])
    return rows


def mean(rows, col, scale=1.0):
    i = COLS.index(col)
    vals = [r[i] for r in rows if r[i] is not None]
    return statistics.fmean(vals) * scale if vals else None


def load_start(rows):
    gputl = [r[0] for r in rows]
    first_idle = next(i for i, v in enumerate(gputl) if v == 0)
    return next(i for i in range(first_idle, len(gputl)) if gputl[i] and gputl[i] > 0)


def completed(path):
    text = path.read_text().replace("\r", "\n")
    done, _total, mm, ss = re.findall(r"(\d+)/(\d+) \[(\d+):(\d+)<", text)[-1]
    return int(done), int(mm) * 60 + int(ss)


run = pathlib.Path(sys.argv[1])

print("vLLM load scenarios, post-hoc")
print("| Scenario | Load start s | Idle samples in registered analysis | Samples | GPUTL % | SMACT % | TENSO % | Power W | GPUTL / SMACT | Completed | Load s | Req/s | Registered GPUTL % | Registered SMACT % |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in (1, 2):
    for s in ("vllm_rate_0.2", "vllm_rate_2", "vllm_saturated"):
        name = f"r{r}_{s}"
        rows = parse(run / f"{name}.dcgm")
        start = load_start(rows)
        idle_in_registered = max(0, start - TRIM)
        loaded = rows[start:-TRIM]
        registered = rows[TRIM:-TRIM]
        g, sm = mean(loaded, "GPUTL"), mean(loaded, "SMACT", 100)
        n, _elapsed = completed(run / f"{name}.stdout")
        load_s = WINDOW - start
        print(f"| {name} | {start} | {idle_in_registered} | {len(loaded)} | {g:.1f} | {sm:.1f} | "
              f"{mean(loaded, 'TENSO', 100):.1f} | {mean(loaded, 'POWER'):.0f} | {g / sm:.2f}x | "
              f"{n} | {load_s} | {n / load_s:.2f} | {mean(registered, 'GPUTL'):.1f} | {mean(registered, 'SMACT', 100):.1f} |")

print()
print("Training, post-hoc")
print("| Scenario | Steps | Batch | Seq | Seconds | Real tokens | Real tokens/s | Token slots/s | Real tokens per slot |")
print("|---|---|---|---|---|---|---|---|---|")
for r in (1, 2):
    for s in ("train_untuned", "train_tuned"):
        name = f"r{r}_{s}"
        line = [l for l in (run / f"{name}.stdout").read_text().splitlines() if l.startswith("{")][-1]
        j = json.loads(line)
        slots = j["steps"] * j["batch_size"] * j["seq"]
        print(f"| {name} | {j['steps']} | {j['batch_size']} | {j['seq']} | {j['seconds']} | {j['tokens']} | "
              f"{j['tokens_per_second']} | {slots / j['seconds']:.0f} | {j['tokens'] / slots:.3f} |")

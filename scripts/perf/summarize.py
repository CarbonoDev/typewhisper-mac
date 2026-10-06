#!/usr/bin/env python3
"""Summarize PERF| lines from benchmark runs into a before/after markdown table.

Usage: summarize.py <before-log>... -- <after-log>...

Each log is one full suite run. Per benchmark and side, the reported value is the median of the
per-run medians; the spread is the min-max of those per-run medians (run-to-run variation).
"""
import statistics
import sys
from collections import defaultdict

def parse(paths):
    runs = defaultdict(list)      # name -> [median per run]
    extras = {}
    for path in paths:
        for line in open(path, encoding="utf-8", errors="replace"):
            if not line.startswith("PERF|"):
                continue
            _, _label, name, median, _lo, _hi, _n, extra = line.rstrip("\n").split("|", 7)
            runs[name].append(float(median))
            extras[name] = extra
    return runs, extras

def fmt(values):
    if not values:
        return "—", ""
    mid = statistics.median(values)
    return f"{mid:.3f}", f"{min(values):.3f}–{max(values):.3f}"

def main(argv):
    split = argv.index("--")
    before, before_extra = parse(argv[:split])
    after, after_extra = parse(argv[split + 1:])
    names = list(dict.fromkeys(list(before) + list(after)))
    print("| Benchmark | Before ms (spread) | After ms (spread) | After/Before | Before extra | After extra |")
    print("|---|---|---|---|---|---|")
    for name in names:
        b, bs = fmt(before.get(name, []))
        a, as_ = fmt(after.get(name, []))
        ratio = "—"
        if before.get(name) and after.get(name):
            bm, am = statistics.median(before[name]), statistics.median(after[name])
            ratio = f"{am / bm:.2f}×" if bm > 0 else "—"
        print(f"| {name} | {b} ({bs}) | {a} ({as_}) | {ratio} | {before_extra.get(name, '')} | {after_extra.get(name, '')} |")

if __name__ == "__main__":
    main(sys.argv[1:])

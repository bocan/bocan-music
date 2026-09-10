#!/usr/bin/env python3
"""vital-signs-trend.py: show docs/vital-signs.csv as one column per run.

Usage: Scripts/vital-signs-trend.py [N] [--csv PATH] [--filter TEXT]

  N              number of most recent runs to show as columns (default 6)
  --csv PATH     history file (default docs/vital-signs.csv)
  --filter TEXT  only metrics whose name contains TEXT (case-insensitive)

The history is the long-format CSV that `Scripts/vital-signs.sh --record`
appends to: date, commit, label, metric, value, unit, note. This script
pivots it: one row per metric, one column per run (headed by the run's label,
or its date when unlabelled), the change against the previous recorded value,
and a sparkline over every recorded run, not only the ones shown. An empty
cell is a run where the metric was unmeasured or absent.
"""

import csv
import sys
from collections import OrderedDict

BARS = "▁▂▃▄▅▆▇█"
GAP = "·"


def to_float(text):
    text = (text or "").strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def fmt_delta(last, prev):
    diff = last - prev
    if diff == 0:
        return "0"
    if float(last).is_integer() and float(prev).is_integer():
        return f"{int(diff):+d}"
    return f"{diff:+.2f}".rstrip("0").rstrip(".")


def sparkline(values):
    numbers = [v for v in values if v is not None]
    if not numbers:
        return ""
    low, high = min(numbers), max(numbers)
    out = []
    for v in values:
        if v is None:
            out.append(GAP)
        elif high == low:
            out.append(BARS[4])
        else:
            idx = int(round((v - low) / (high - low) * (len(BARS) - 1)))
            out.append(BARS[idx])
    return "".join(out)


def parse_args(argv):
    count, path, needle = 6, "docs/vital-signs.csv", ""
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-h", "--help"):
            print(__doc__.strip())
            sys.exit(0)
        if arg == "--csv":
            i += 1
            path = argv[i]
        elif arg == "--filter":
            i += 1
            needle = argv[i].lower()
        elif arg.isdigit():
            count = int(arg)
        else:
            sys.exit(f"unknown argument: {arg}")
        i += 1
    return count, path, needle


def main():
    count, path, needle = parse_args(sys.argv[1:])
    try:
        with open(path, newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    except FileNotFoundError:
        sys.exit(f"no history at {path}; run Scripts/vital-signs.sh --record first")
    if not rows:
        sys.exit(f"{path} has a header and no rows")

    runs = OrderedDict()   # (date, commit, label) -> {metric: value text}
    units = OrderedDict()  # metric -> unit, in first-seen order
    for row in rows:
        key = (row["date"], row["commit"], row["label"])
        runs.setdefault(key, {})[row["metric"]] = row["value"].strip()
        units.setdefault(row["metric"], "")
        if row["unit"]:
            units[row["metric"]] = row["unit"]

    keys = sorted(runs, key=lambda k: k[0])
    shown = keys[-count:]

    def head(key):
        return key[2] or key[0][:10]

    print("| Metric | " + " | ".join(head(k) for k in shown) + " | Δ | Trend |")
    print("|---|" + "---:|" * len(shown) + "---:|---|")

    for metric, unit in units.items():
        if needle and needle not in metric.lower():
            continue
        series = [to_float(runs[k].get(metric)) for k in keys]
        cells = [runs[k].get(metric, "") for k in shown]
        last = series[-1]
        earlier = [v for v in series[:-1] if v is not None]
        if last is None:
            delta = ""
        elif not earlier:
            delta = "new"
        else:
            delta = fmt_delta(last, earlier[-1])
        name = f"{metric} ({unit})" if unit else metric
        print(f"| {name} | " + " | ".join(cells) + f" | {delta} | {sparkline(series)} |")


if __name__ == "__main__":
    main()

"""Why order numbers repeat between two tills, read from full-day stress reports.

Usage:
    python tools/stress_number_forensics.py [report.json ...]

With no arguments it reads every stress-day-*.json in this till's
stress_reports folder. Copy the other till's reports next to them to see
both sides of each collision.

How a number is given (lib/core/lan/lan_wiring.dart, lan_number_desk.dart):
  * the primary numbers from its own counter;
  * a secondary holds ONE number reserved from the primary and asks for the
    next only after using it; anything numbered while that ask is in flight,
    or with no primary in sight, is numbered locally from the secondary's own
    counter, which the primary does not know about.
So a secondary stamping two numbers close together (two cashiers paying, or a
split that makes several checks in one tap) numbers the second one locally,
and the primary hands the same number to its own sale.
"""

import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime

# Steps that stamp an order number (PosSession._stampOrderNo): park, pay, and
# every check a split makes.
STAMPING = ("hold", "pay", "pay own items", "split by items", "share ")
# A reserve round trip on shop wifi; two stamps closer than this cannot both
# have had a number from the primary.
REFILL_WINDOW_MS = 1000

COLLISION = re.compile(r"Number #(\d+) is also on (\w+) @(\S+)")


def reports(args):
    if args:
        return args
    base = os.path.join(os.environ["APPDATA"], "Code Solution", "Offline POS", "stress_reports")
    return sorted(glob.glob(os.path.join(base, "stress-day-*.json")))


def stamps(order):
    out = []
    for e in order["events"]:
        if e["step"].startswith(STAMPING) and not e["failed"]:
            out.append((datetime.fromisoformat(e["at"]), e["step"]))
    return out


def analyse(path):
    run = json.load(open(path, encoding="utf-8"))
    device = run["device"]
    orders = run["orders"]
    timeline = sorted(
        (at, o["index"], step, o["cashier"]) for o in orders for at, step in stamps(o)
    )
    collided = defaultdict(set)
    for o in orders:
        for p in o["problems"]:
            m = COLLISION.match(p["text"])
            if m:
                collided[o["index"]].add((int(m.group(1)), m.group(3)[:8]))

    causes = Counter()
    rows = []
    for o in orders:
        if o["index"] not in collided:
            continue
        mine = stamps(o)
        first = mine[0][0] if mine else None
        crowd = [
            t for t in timeline
            if first and t[1] != o["index"]
            and 0 <= (first - t[0]).total_seconds() * 1000 < REFILL_WINDOW_MS
        ]
        own_burst = len(mine) > 1 and (mine[-1][0] - mine[0][0]).total_seconds() * 1000 < REFILL_WINDOW_MS * 3
        if crowd:
            cause = "another cashier on this till stamped a number just before"
        elif own_burst or o["split_into"]:
            cause = "one action stamped several numbers (split / pay again)"
        else:
            cause = "number given while the primary was not answering, or this till is the primary"
        causes[cause] += 1
        rows.append((o, sorted(collided[o["index"]]), cause, crowd))
    return run, device, orders, rows, causes, timeline


def main():
    paths = reports(sys.argv[1:])
    if not paths:
        print("No stress-day reports found.")
        return
    total = Counter()
    for path in paths:
        run, device, orders, rows, causes, timeline = analyse(path)
        if not rows:
            continue
        print("=" * 78)
        print(f"{os.path.basename(path)}")
        print(f"till {device[:8]} · {len(orders)} orders · {len(rows)} with a repeated number")
        gaps = [
            (b[0] - a[0]).total_seconds() * 1000
            for a, b in zip(timeline, timeline[1:])
        ]
        close = sum(1 for g in gaps if g < REFILL_WINDOW_MS)
        print(f"numbers stamped on this till: {len(timeline)} · "
              f"{close} of them under {REFILL_WINDOW_MS} ms after the previous one")
        for o, nums, cause, crowd in rows:
            print(f"  #{o['order_no']:<5} {o['scenario']:<18} {o['cashier']:<9} "
                  f"repeated {', '.join(f'#{n}@{d}' for n, d in nums)}")
            print(f"         cause: {cause}")
            for at, idx, step, cashier in crowd[-2:]:
                print(f"         · {at.time()} order {idx} {step} by {cashier}")
        for cause, n in causes.most_common():
            print(f"  {n:>3} × {cause}")
        total.update(causes)
    print("=" * 78)
    print("All runs:")
    for cause, n in total.most_common():
        print(f"  {n:>3} × {cause}")


if __name__ == "__main__":
    main()

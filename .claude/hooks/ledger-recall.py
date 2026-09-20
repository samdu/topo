#!/usr/bin/env python3
"""The PM's ledger, read back after a compaction (docs/process.md).

A compacted coordinator's expensive failure is re-dispatching work that is
already done, so on every session start that is not a fresh launch — a resume,
and above all a compaction — the tail of each open plan's ledger goes back into
the context without being asked for.

Open means the file has no ``merged:`` line. Stdout from a SessionStart hook is
added to the session as context; nothing here blocks anything.
"""
import glob
import json
import os
import sys

LEDGERS = os.path.expanduser("~/Desktop/topo-plans/progress-*.md")
TAIL = 12          # lines of each ledger, newest last
MAX_LEDGERS = 6    # the newest few; an old plan's tail is not what a compaction lost


def tail_of(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = [l.rstrip() for l in f if l.strip()]
    if any(l.startswith("- ") and " merged:" in l for l in lines):
        return None
    head = [l for l in lines if l.startswith(("branch:", "plan:"))]
    events = [l for l in lines if l.startswith("- ")]
    return "\n".join(head + (["…"] if len(events) > TAIL else []) + events[-TAIL:])


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        d = {}
    if d.get("source") == "startup":
        return  # a fresh session reads the ledgers itself, as the brief tells it to
    paths = sorted(glob.glob(LEDGERS), key=os.path.getmtime, reverse=True)[:MAX_LEDGERS]
    out = [t for t in (tail_of(p) for p in paths) if t]
    if not out:
        return
    print("The open plans' ledgers (docs/process.md). These, and `git log`, are what "
          "happened on each branch — not your recollection of it.\n")
    print("\n\n".join(out))


if __name__ == "__main__":
    main()

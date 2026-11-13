#!/usr/bin/env python3
"""The sprint's ledger, read back after a compaction (docs/sprints.md).

A compacted PM's expensive failure is re-dispatching work that is already
done, so on every session start that is not a fresh launch — a resume, and
above all a compaction — the tail of the current sprint's ledger
(``~/topo-plans/sprints/current/ledger.md``) goes back into the context
without being asked for. A fresh launch reads the ledger itself, as the PM's
brief tells it to.

Stdout from a SessionStart hook is added to the session as context; nothing
here blocks anything, and a ledger that is missing or unreadable prints
nothing.
"""
import json
import os
import sys

LEDGER = os.path.expanduser("~/topo-plans/sprints/current/ledger.md")
TAIL = 30   # lines, newest last


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        d = {}
    if d.get("source") == "startup":
        return
    try:
        with open(LEDGER, encoding="utf-8", errors="replace") as f:
            lines = [l.rstrip() for l in f if l.strip()]
    except OSError:
        return
    if not lines:
        return
    print("The sprint's ledger, its last lines (docs/sprints.md). These, and `git log`, are what "
          "happened — not your recollection of it.\n")
    if len(lines) > TAIL:
        print("…")
    print("\n".join(lines[-TAIL:]))


if __name__ == "__main__":
    main()

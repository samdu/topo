#!/usr/bin/env python3
"""The coordinator's ledger, read back after a compaction (docs/process.md).

A compacted coordinator's expensive failure is re-dispatching work that is
already done, so on every session start that is not a fresh launch — a resume,
and above all a compaction — the tail of each open plan's ledger goes back into
the context without being asked for.

Open means the file has no ``merged:`` line. The open sprint's ledger
(docs/sprints.md) comes back too, folded to its scope and each item's state,
since a coordinator that re-derives its scope from memory is how scope grows
unseen. Stdout from a SessionStart hook is
added to the session as context; nothing here blocks anything.
"""
import glob
import json
import os
import sys

LEDGERS = os.path.expanduser("~/topo-plans/progress-*.md")
SPRINTS = os.path.expanduser("~/topo-plans/sprints/*.jsonl")
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


def open_sprint():
    """The newest sprint ledger without a ``close`` line, folded; or None."""
    paths = [p for p in glob.glob(SPRINTS) if ".sync-conflict-" not in p]
    for path in sorted(paths, key=os.path.getmtime, reverse=True)[:1]:
        events = []
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    events.append(json.loads(line))
                except ValueError:
                    continue  # a line half-synced is read on the next start
        if not events or any(e.get("kind") == "close" for e in events):
            return None
        opened = next((e for e in events if e.get("kind") == "open"), {})
        items = {}
        for e in events:
            if e.get("kind") == "item":
                items[e.get("id")] = dict(e, status="todo")
            elif e.get("kind") == "status" and e.get("id") in items:
                items[e["id"]].update(status=e.get("status"), pr=e.get("pr", items[e["id"]].get("pr")))
        name = os.path.basename(path)[:-len(".jsonl")]
        out = [f"sprint {name}: {opened.get('goal', '')} — ends {opened.get('ends', '?')}",
               f"scope at open: {', '.join(opened.get('scope', []))}"]
        for i in items.values():
            pr = f" #{i['pr']}" if i.get("pr") else ""
            parent = f" <- {', '.join(map(str, i.get('parent') or []))}" if i.get("parent") else ""
            out.append(f"- {i.get('id')} [{i.get('origin')}] {i.get('status')}{pr}{parent} {i.get('title', '')}")
        return "\n".join(out)
    return None


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        d = {}
    if d.get("source") == "startup":
        return  # a fresh session reads the ledgers itself, as the brief tells it to
    # Syncthing's conflict copies match the glob too, and hold an older ledger.
    paths = [p for p in glob.glob(LEDGERS) if ".sync-conflict-" not in p]
    paths = sorted(paths, key=os.path.getmtime, reverse=True)[:MAX_LEDGERS]
    out = [t for t in (tail_of(p) for p in paths) if t]
    sprint = open_sprint()
    if sprint:
        print("The open sprint (docs/sprints.md). Its scope is what was agreed at open; "
              "you do not add to it.\n")
        print(sprint + "\n")
    if not out:
        return
    print("The open plans' ledgers (docs/process.md). These, and `git log`, are what "
          "happened on each branch — not your recollection of it.\n")
    print("\n\n".join(out))


if __name__ == "__main__":
    main()

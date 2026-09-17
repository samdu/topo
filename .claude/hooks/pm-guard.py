#!/usr/bin/env python3
"""The Topo PM's guard (docs/process.md).

Applies to any session whose working directory is this checkout — the PM's —
and to the subagents it runs, which share its hooks. It blocks two things the
process forbids the PM:

1. Editing code in THIS checkout. Engineers edit in their own worktrees under
   ~/github/.worktrees/, which are different paths, so the deny falls on the
   PM's checkout alone. Docs stay editable: the PM owns docs/, CLAUDE.md and
   .claude/.
2. Delegating at its own cost: ``subagent_type: fork`` inherits the PM's model,
   and an explicit ``model`` overrides the agent definition's. The agent
   definitions are the only place a worker's model is set.

Reads the PreToolUse JSON on stdin; exit 2 with a reason on stderr blocks.
"""
import json
import os
import sys

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
CODE = ("Apps", "Packages", "Tests", "Womble")


def block(msg: str) -> None:
    print(msg, file=sys.stderr)
    sys.exit(2)


def main() -> None:
    d = json.load(sys.stdin)
    tool = d.get("tool_name", "")
    ti = d.get("tool_input") or {}
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        p = ti.get("file_path") or ti.get("notebook_path") or ""
        rp = os.path.realpath(p) if p else ""
        if rp.startswith(ROOT + os.sep):
            rel = os.path.relpath(rp, ROOT)
            if rel.split(os.sep, 1)[0] in CODE or rel == "project.yml":
                block(f"PM guard: {rel} is code. The PM plans; an engineer edits it in its own worktree (docs/process.md).")
    elif tool == "Agent":
        if ti.get("subagent_type") == "fork":
            block("PM guard: no fork — a fork runs at the PM's model. Use general-purpose or Explore.")
        if ti.get("model"):
            block("PM guard: no model override — a worker's model comes from its agent definition.")


if __name__ == "__main__":
    main()

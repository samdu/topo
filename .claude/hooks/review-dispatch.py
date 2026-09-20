#!/usr/bin/env python3
"""Anti-pre-judging on a review dispatch (docs/process.md).

The PM says what changed and what to read, and nothing about what to conclude.
A dispatch that tells a reviewer what not to flag, or how far to downgrade a
finding it does find, is refused: pre-judging a review has cost us findings we
then paid for in a later round. A defect the plan mandated is still reported —
Important, tagged plan-mandated — and adjudicated against the spec.

Reads the PreToolUse JSON on stdin; exit 2 with a reason on stderr blocks.
Applies to an ``Agent`` whose prompt is a review, and to a Bash line running
the plan reviewer or codex.
"""
import json
import re
import sys

REVIEW = re.compile(r"\breview(er|ing|s)?\b|\bfinding(s)?\b|\bverdict\b", re.I)
STEER = [
    (re.compile(r"\b(don'?t|do not|no need to|needn'?t)\s+(flag|report|raise|mention)\b", re.I),
     "it tells the reviewer what not to report"),
    (re.compile(r"\bat most\s+(a\s+)?(minor|nit|low)\b", re.I),
     "it caps a finding's severity in advance"),
    (re.compile(r"\b(as|to)\s+(at most\s+)?(minor|non-?blocking|informational)\b", re.I),
     "it caps a finding's severity in advance"),
    (re.compile(r"\bnot a (real )?(finding|defect|bug)\b", re.I),
     "it decides a finding before the reviewer has read the code"),
    (re.compile(r"\b(intentional|by design|deliberate|expected)\b[^.]{0,80}\b(so|hence|therefore)\b[^.]{0,60}\b(ignore|skip|don'?t|no need)\b", re.I),
     "implementer rationale does not downgrade a finding — only the spec or a recorded ruling does"),
    (re.compile(r"\b(ignore|skip|leave out)\s+(any|all|the)\s+(findings?|issues?|concerns?)\b", re.I),
     "it tells the reviewer what not to report"),
]


def main():
    d = json.load(sys.stdin)
    tool = d.get("tool_name", "")
    ti = d.get("tool_input") or {}
    if tool == "Agent":
        text = str(ti.get("prompt") or "")
        if not REVIEW.search(text):
            return
    elif tool == "Bash":
        text = str(ti.get("command") or "")
        if "plan-review.sh" not in text and "codex" not in text:
            return
    else:
        return
    for pat, why in STEER:
        m = pat.search(text)
        if m:
            print(f"Review dispatch guard: {why} (“{m.group(0)}”). Say what changed and what "
                  "to read; a plan-mandated defect is reported Important and tagged, and a "
                  "disagreement is a recorded ruling (docs/process.md).", file=sys.stderr)
            sys.exit(2)


if __name__ == "__main__":
    main()

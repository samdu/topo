#!/usr/bin/env python3
"""Anti-pre-judging on a review dispatch (docs/process.md).

The coordinator says what changed and what to read, and nothing about what to conclude.
A dispatch that tells a reviewer what not to flag, or how far to downgrade a
finding it does find, is refused: pre-judging a review has cost us findings we
then paid for in a later round. A defect the plan mandated is still reported —
Important, tagged plan-mandated — and adjudicated against the spec.

Reads the PreToolUse JSON on stdin; exit 2 with a reason on stderr blocks.
Applies to an ``Agent`` dispatch of a reviewer agent (``REVIEWERS``), and to a
Bash command that runs the plan reviewer or Codex (``RUNS``): not to every
prompt or command that mentions a review. Two things in a dispatch are not
steering: a passage quoted word for word from the project's CLAUDE.md, which
the reviewer reads anyway, and a sentence citing a recorded ruling (a ruling
or a ledger line, with its date), which is the one thing docs/process.md lets
settle a finding in advance.
"""
import json
import os
import re
import sys

REVIEWERS = {"adversarial-reviewer"}
RUNS = re.compile(r"(?:^|[\s;&|(`])(?:\S*/)?(?:plan-review\.sh\b|codex\s+(?:exec|review)\b)")
RULING = re.compile(r"\b(?:rul(?:ing|ed)|ledger)\b[^.\n]*\b\d{4}-\d{2}-\d{2}|\b\d{4}-\d{2}-\d{2}\b[^.\n]*\b(?:rul(?:ing|ed)|ledger)\b", re.I)
QUOTED = 20   # characters either side of a match that must also be CLAUDE.md's for it to be a quotation
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


def squash(text):
    return re.sub(r"\s+", " ", text)


def project_rules():
    try:
        with open(os.path.join(os.environ.get("CLAUDE_PROJECT_DIR") or ".", "CLAUDE.md"), encoding="utf-8") as f:
            return squash(f.read())
    except OSError:
        return ""


def quoted(text, m, rules):
    """Whether the match is inside a passage of CLAUDE.md the dispatch quotes:
    the run of the dispatch around it that is CLAUDE.md's word for word, grown
    a character at a time either way, reaches QUOTED characters past it."""
    def held(a, b):
        return squash(text[a:b]) in rules
    a, b = m.start(), m.end()
    if not rules or not held(a, b):
        return False
    while a > 0 and held(a - 1, b):
        a -= 1
    while b < len(text) and held(a, b + 1):
        b += 1
    return (m.start() - a) + (b - m.end()) >= QUOTED


def sentence(text, m):
    a = max(text.rfind(".", 0, m.start()), text.rfind("\n", 0, m.start())) + 1
    ends = [i for i in (text.find(".", m.end()), text.find("\n", m.end())) if i >= 0]
    return text[a:min(ends) if ends else len(text)]


def main():
    d = json.load(sys.stdin)
    tool = d.get("tool_name", "")
    ti = d.get("tool_input") or {}
    if tool == "Agent":
        if ti.get("subagent_type") not in REVIEWERS:
            return
        text = str(ti.get("prompt") or "")
    elif tool == "Bash":
        text = str(ti.get("command") or "")
        if not RUNS.search(text):
            return
    else:
        return
    rules = None
    for pat, why in STEER:
        for m in pat.finditer(text):
            if rules is None:
                rules = project_rules()
            if quoted(text, m, rules) or RULING.search(sentence(text, m)):
                continue
            print(f"Review dispatch guard: {why} (“{m.group(0)}”). Say what changed and what "
                  "to read; a plan-mandated defect is reported Important and tagged, and a "
                  "disagreement is a recorded ruling, cited with its date (docs/process.md).", file=sys.stderr)
            sys.exit(2)


if __name__ == "__main__":
    main()

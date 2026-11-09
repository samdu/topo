#!/usr/bin/env python3
"""Anti-pre-judging on a review dispatch (docs/process.md).

The coordinator says what changed and what to read, and nothing about what to conclude.
A dispatch that tells a reviewer what not to flag, or how far to downgrade a
finding it does find, is refused: pre-judging a review has cost us findings we
then paid for in a later round. A defect the plan mandated is still reported —
Important, tagged plan-mandated — and adjudicated against the spec.

Reads the PreToolUse JSON on stdin; exit 2 with a reason on stderr blocks.
Applies to an ``Agent`` dispatch of a reviewer agent (``REVIEWERS``), and to a
Bash command whose text, with its line continuations joined and its quotes and
backslashes taken out, names the plan reviewer, or ``codex`` with ``exec``, ``e``
or ``review`` later on the same line (``INVOKES``): such a command is read whole. No shell is
parsed, so prose that names the invocation is read too, and a name put together
when the command runs is not. Two things in a dispatch are not steering: a
passage quoted word for word from the project's CLAUDE.md (a sentence, or a
quoted string's contents, that is CLAUDE.md's and runs QUOTED characters past
the match on each side), which the reviewer reads anyway, and a sentence citing
a recorded ruling (a ruling or a ledger line, with its date), which is the one
thing docs/process.md lets settle a finding in advance. Anything that goes
wrong while reading a dispatch refuses it.
"""
import json
import os
import re
import sys

REVIEWERS = {"adversarial-reviewer"}
# The plan reviewer, or Codex with exec, its alias e or review later on the same line
# (options between included). Case-sensitive, so prose about "the Codex reviewer" is not it.
INVOKES = re.compile(r"\bcodex\b.*?\b(?:exec|e|review)\b|plan-review\.sh")
ENDS = ".!?\n"                 # what ends a sentence
QUOTES = '"“”`'      # what bounds a quotation in a prompt
SHELL_QUOTES = QUOTES + "'"    # and in a command, where ' quotes too
RULING = re.compile(r"\b(?:rul(?:ing|ed)|ledger)\b[^.!?\n]*\b\d{4}-\d{2}-\d{2}|\b\d{4}-\d{2}-\d{2}\b[^.!?\n]*\b(?:rul(?:ing|ed)|ledger)\b", re.I)
QUOTED = 20   # characters of the quotation either side of a match, for it to be a quotation
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


def span(text, m, ends):
    """The run of text holding the match, bounded by any character of ``ends``."""
    a = max(text.rfind(c, 0, m.start()) for c in ends) + 1
    after = [i for i in (text.find(c, m.end()) for c in ends) if i >= 0]
    return a, min(after) if after else len(text)


def quoted(text, m, rules, quotes):
    """Whether the match is inside a passage the dispatch quotes from CLAUDE.md:
    the sentence holding it, or the quoted string holding it, is CLAUDE.md's word
    for word and runs QUOTED characters past the match on each side. In a command
    a quoted string is bounded by ' too, and is also read as bounded by double
    quotes alone, so an apostrophe inside a double-quoted passage does not cut it."""
    if not rules:
        return False
    for ends in (ENDS, ENDS + QUOTES, ENDS + quotes):
        a, b = span(text, m, ends)
        if (squash(text[a:b]).strip() in rules
                and len(text[a:m.start()].strip()) >= QUOTED
                and len(text[m.end():b].strip()) >= QUOTED):
            return True
    return False


def sentence(text, m):
    a, b = span(text, m, ENDS)
    return text[a:b]


def refuse(why, said):
    print(f"Review dispatch guard: {why} (“{said}”). Say what changed and what "
          "to read; a plan-mandated defect is reported Important and tagged, and a "
          "disagreement is a recorded ruling, cited with its date (docs/process.md).", file=sys.stderr)
    sys.exit(2)


def judge(d):
    tool = d.get("tool_name", "")
    ti = d.get("tool_input") or {}
    if tool == "Agent":
        if ti.get("subagent_type") not in REVIEWERS:
            return
        text, quotes = str(ti.get("prompt") or ""), QUOTES
    elif tool == "Bash":
        text, quotes = str(ti.get("command") or ""), SHELL_QUOTES
        if not INVOKES.search(re.sub(r"['\"\\]", "", text.replace("\\\n", ""))):
            return
    else:
        return
    rules = None
    for pat, why in STEER:
        for m in pat.finditer(text):
            if rules is None:
                rules = project_rules()
            if quoted(text, m, rules, quotes) or RULING.search(sentence(text, m)):
                continue
            refuse(why, m.group(0))


def main():
    try:
        judge(json.load(sys.stdin))
    except SystemExit:
        raise
    except Exception as e:  # a dispatch the guard could not read is not let through
        refuse(f"it could not be read ({type(e).__name__})", "")


if __name__ == "__main__":
    main()

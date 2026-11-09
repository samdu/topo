#!/usr/bin/env python3
"""Anti-pre-judging on a review dispatch (docs/process.md).

The coordinator says what changed and what to read, and nothing about what to conclude.
A dispatch that tells a reviewer what not to flag, or how far to downgrade a
finding it does find, is refused: pre-judging a review has cost us findings we
then paid for in a later round. A defect the plan mandated is still reported —
Important, tagged plan-mandated — and adjudicated against the spec.

Reads the PreToolUse JSON on stdin; exit 2 with a reason on stderr blocks.
Applies to an ``Agent`` dispatch of a reviewer agent (``REVIEWERS``), and to a
Bash command that runs the plan reviewer or Codex (``runs``): not to every
prompt or command that mentions a review. Two things in a dispatch are not
steering: a passage quoted word for word from the project's CLAUDE.md (the
sentence holding the match, or the quotation within it, with QUOTED characters
of it either side of the match), which the reviewer reads anyway, and a sentence citing a recorded ruling (a ruling
or a ledger line, with its date), which is the one thing docs/process.md lets
settle a finding in advance.
"""
import json
import os
import re
import shlex
import sys

REVIEWERS = {"adversarial-reviewer"}
SHELLS = {"bash", "sh", "zsh"}
ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
ENDS = ".!?\n"          # what ends a sentence
QUOTES = '"\u201c\u201d`'  # what bounds a quotation inside one
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


def quoted(text, m, rules):
    """Whether the match is inside a passage the dispatch quotes from CLAUDE.md:
    the sentence holding it, or the quotation within that sentence, is
    CLAUDE.md's word for word, and runs QUOTED characters past the match on
    each side."""
    if not rules:
        return False
    a, b = span(text, m, ENDS + QUOTES)
    return (squash(text[a:b]).strip() in rules
            and len(text[a:m.start()].strip()) >= QUOTED
            and len(text[m.end():b].strip()) >= QUOTED)


def sentence(text, m):
    a, b = span(text, m, ENDS)
    return text[a:b]


def segments(command):
    """The simple commands of a shell command line, each as its words: split at
    ; & | ( ) and newlines outside quotes, quotes taken off."""
    lex = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    words = []
    for tok in lex:
        if tok and all(c in ";&|()\n" for c in tok):
            if words:
                yield words
            words = []
        else:
            words.append(tok)
    if words:
        yield words


def runs(command, depth=0):
    """The text of each part of the command that runs the plan reviewer or
    Codex, read by its command word, so an argument that names them is not."""
    try:
        parts = list(segments(command))
    except ValueError:  # an unclosed quote: read the whole line
        return [command] if re.search(r"plan-review\.sh|codex", command) else []
    found = []
    for words in parts:
        while words and ASSIGN.match(words[0]):
            words = words[1:]
        if not words:
            continue
        name = os.path.basename(words[0])
        if name == "plan-review.sh" or (name == "codex" and words[1:2] in (["exec"], ["review"])):
            found.append(" ".join(words))
        elif name in SHELLS and depth < 3:
            for i, w in enumerate(words[1:-1], 1):
                if w.startswith("-") and "c" in w[1:]:
                    found += runs(words[i + 1], depth + 1)
                    break
    return found


def main():
    d = json.load(sys.stdin)
    tool = d.get("tool_name", "")
    ti = d.get("tool_input") or {}
    if tool == "Agent":
        if ti.get("subagent_type") not in REVIEWERS:
            return
        text = str(ti.get("prompt") or "")
    elif tool == "Bash":
        text = "\n".join(runs(str(ti.get("command") or "")))
        if not text:
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

# Sprints

Topo's work runs in sprints: a list agreed with Sam at the start, worked to the end, and a short review he reads at the close. A sprint exists so that how the work went can be measured inside a window: what was planned, what merged, what turned up on the way, and what it cost. Its length follows the work (two or three days is usual with agents); what bounds it is Sam's review time and the token budget, not a calendar. The coordinator runs it (`docs/coordinator-brief.md` is the brief a coordinator session starts from); `docs/process.md` is how each item on the list lands.

> **Provisional.** Choices that wait on Sam's answer are drafted around the recommended one and marked *(provisional, Q<n>)*, here and in `docs/coordinator-brief.md`. The questions are in this PR's description.

## The scope line

The list agreed at open is the sprint's scope, and it is written once. Nothing the coordinator does adds to it.

- **Planned** items are the list.
- **Discovered** items are work found during the sprint. One that blocks a planned item (that item cannot merge, or its suites cannot pass, without it) is done in the sprint and recorded as discovered, with its parent. Anything else found, a reviewer's non-blocking finding, a neighbouring weakness, tidying, is filed as an issue labelled `backlog` and recorded as found; it is a candidate for a later sprint, not work for this one.
- A discovered item whose parent is itself discovered (a follow-up of a follow-up) is not started without Sam's word in the coordinator's thread *(provisional, Q3)*. The ask names the chain.
- Sam can add to the list mid-sprint. That is an `item` line with `origin: planned` and his words quoted in `words`, so growth is always visible and never silent.

## The ledger

One file per sprint, `~/topo-plans/sprints/<id>.jsonl` (ids `s1`, `s2`, … in order), in the `topo-plans` Syncthing folder toolbox and buddybox share. It is the source for the close review and for the queue pane, which reads it on buddybox. Like the plan ledgers (`docs/process.md`, *The ledger*) it is append-only: one JSON object per line, newest last, nothing edited or removed. The current state of an item is the fold of its lines.

Every line has `at` (UTC, `2026-11-10T17:40Z`) and `kind`. The kinds:

| kind | fields | written when |
|---|---|---|
| `open` | `goal`, `ends` (UTC), `scope` (list of item ids), `agreed` (Sam's words, quoted) | the sprint opens; the first line, written once |
| `item` | `id`, `title`, `origin` (`planned` or `discovered`), `parent` (list of item ids, `#PR`s or `#issue`s; empty for work nobody's PR turned up), `plan` (plan file, if any), `words` (Sam's, quoted, on an item he added mid-sprint) | an item is first recorded: every planned item straight after `open`, an added or discovered one when it is |
| `status` | `id`, `status`, `pr` (once there is one), `sha` (where there is one), `why` (on `dropped`), `rounds` (on `merged`: the Codex verdicts `scripts/review-cap.sh` counts on its PR) | an item moves |
| `found` | `issue`, `title`, `parent` | work is found and sent to the backlog |
| `env` | `what`, `cost`, `fixed` (bool) | an environment failure is worked around or fixed (CLAUDE.md, *Working here*) |
| `close` | `reason` (`done`, `time`), `review` (path of the review) | the sprint closes; the last line |

`status` is one of `todo`, `building`, `draft`, `ready`, `merged`, `dropped` (with a `why`) and `rolled` (carried to the next sprint at close). An item's `pr` is its PR on samdu/topo. A backlog issue picked up in a later sprint is an `item` whose `parent` holds that issue, which is how a chain is followed across sprints; an item that becomes more than one PR is more than one item. Ids are `<sprint>.<n>`, numbered as recorded (`s1.7`), so an id says which sprint found it.

```jsonl
{"at":"2026-11-11T17:05Z","kind":"open","goal":"Land the audit's built fixes","ends":"2026-11-14T01:00Z","scope":["s1.1","s1.2"],"agreed":"yes, those two and nothing else"}
{"at":"2026-11-11T17:05Z","kind":"item","id":"s1.1","title":"Control secrets reach the keychain on a queue of their own","origin":"planned","parent":[],"plan":"plan-code-audit.md"}
{"at":"2026-11-11T17:05Z","kind":"item","id":"s1.2","title":"Shared TopoProxy test support","origin":"planned","parent":[],"plan":"plan-code-audit.md"}
{"at":"2026-11-11T19:30Z","kind":"status","id":"s1.1","status":"draft","pr":660,"sha":"4f2a91c"}
{"at":"2026-11-12T02:10Z","kind":"item","id":"s1.3","title":"A secret set across a sign-out keeps nothing","origin":"discovered","parent":["s1.1"]}
{"at":"2026-11-12T02:12Z","kind":"found","issue":681,"title":"The keychain queue's teardown is outside LoginLife","parent":["s1.1"]}
{"at":"2026-11-12T08:40Z","kind":"env","what":"others fails on both laptops at the crash probe's test","cost":"laptops idle, every run on buddybox, ~2x queue","fixed":false}
```

The plan ledgers (`progress-<topic>.md`) stay as they are: they hold one branch's events at the grain of a fix round, and an item's `plan` names which one to read.

## Opening a sprint

1. The coordinator drafts the list from the backlog, the roadmap and the last review's carry-overs: each item a title, a size, and the plan it needs. It sizes the list to the sprint's length against the suite-minutes and Codex rounds the last sprint actually spent.
2. It puts the list to Sam on the decisions pane (`decisions-post --decision`), with an end date. The pane card's reply is the agreement.
3. On his word it writes `open` and one `item` per entry, and starts work. Nothing is dispatched before `open` is written.

## During

The coordinator works the list through `docs/process.md`, writing a `status` line as each item moves, not in a batch. Two things stop it and go to Sam: a discovered item two deep (above), and an environment failure it cannot fix (CLAUDE.md, *Working here*).

## Closing a sprint

A sprint closes when every item is `merged` or `dropped`, or at `ends`, whichever comes first *(provisional, Q1)*. Tokens spent are reported, not a stop. At the close the coordinator:

1. Writes `status: rolled` for each item still open. A rolled item is a candidate for the next list; nothing carries it there by itself.
2. Writes the review (below) to `~/topo-plans/sprints/<id>-review.md` and posts it with `decisions-post --report`.
3. Writes `close`.
4. Drafts the next list with the review, and opens nothing until Sam has agreed it.

## The review

What Sam reads at the close. It is short and leads with the numbers, and each figure has one source, so it can be checked: counts and days are folds of the ledger; Codex rounds the sum of `rounds` on the merged items; suite-minutes the sum of the minutes the `local/*` statuses on the sprint's PRs carry (`docs/testing.md`, *The statuses*); tokens the usage session-store holds for the sessions the sprint ran (the coordinator's and each engineer's). A figure whose source cannot be read is left out and said to be, never estimated.

```markdown
# s1: Land the audit's built fixes — closed 2026-11-13, done

Planned 9 · merged 8 · rolled 1 · dropped 0
Discovered 3 (blocking, done in the sprint) · found 5 (to the backlog)
Days 2.4 of 3 · Codex rounds 14 · suite-minutes 610 · tokens 41M

## Merged
- s1.1 #660 Control secrets reach the keychain on a queue of their own
- s1.3 #667 ← s1.1 A secret set across a sign-out keeps nothing (discovered)

## Rolled
- s1.6 #672 …: one line on why

## Found (backlog)
- #681 ← s1.1 The keychain queue's teardown is outside LoginLife

## Environment
- others failing on both laptops, 7 h of laptop time lost, fixed in #684 / still open: what it costs

## For the next sprint
Three to five candidates, each one line, rolled items first.
```

A discovered item shows its parent (`← s1.1`). A line is the item, never the narrative of how it went; how it went is the plan ledger's.

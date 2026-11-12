# Sprints

Topo's work runs in sprints: a work order Sam agrees at the start, worked to the end by the Topo PM (`docs/process.md`, *The roles*), and a short report card he reads at the close. How each item on the order lands is `docs/process.md`.

## On GitHub

The queue pane (`https://pane.burmese-egret.ts.net/topo-queue/`) draws the sprint from GitHub, so GitHub says what the sprint is:

- **A sprint is a milestone**, named for its start date (`2026-11-11`), and each work-order item is an issue in it. An item added mid-sprint joins the milestone when it is added to the work order. Milestones are for sprints only.
- **Every item's issue and PR is labelled** `planned` (Sam asked for it) or `discovered` (a PR or its review turned it up).
- **A discovered item's body opens with `Follow-up to #N`**, naming its parent.
- **Each roadmap step in `docs/roadmap.md` has a tracking issue**, titled `Roadmap: <step>` and labelled `roadmap`, and an item's issue is a sub-issue of its step's.

GitHub Projects are not used.

## On disk

Each sprint has a directory, `~/topo-plans/sprints/<start date>/`, in the `topo-plans` Syncthing folder buddybox shares, and `~/topo-plans/sprints/current` is a symlink to the one in progress. It holds:

- `plan.md` — the work order, in order. Sam sets it; the PM adds to it only through the follow-up rule, and every addition names its parent.
- `ledger.md` — one line as each thing happens, newest last, timestamps in UTC: dispatched, merged, ruled, deferred, carded. A dispatch line carries the engineer's session name, session ID and PR number, so its transcript can be found in the session store (`session-search`). It is append-only: nothing in it is edited or removed, because its whole value is that it is not a memory. It keeps what GitHub has no place for: why each ruling went as it did, and the session behind each dispatch.
- `brief.md` — the PM's brief as it stood for that sprint.
- Any handoff written during the sprint (`handoff-<session>.md`).

After a compaction or a restart the ledger and `git log` are what happened, and the PM's recollection is not evidence: work that is not in the ledger is checked for in `git log` and on GitHub before it is dispatched again. `.claude/hooks/ledger-recall.py` prints the ledger's last 30 lines into a session in the checkout on a compaction and on a resume, so that memory arrives without being asked for; a fresh launch reads the ledger itself.

## The scope line

The work order agreed at the start is the sprint's size. Work found on the way goes where `docs/process.md`'s *Follow-up work* sends it: into its PR only if the PR cannot be correct without it, a new item this sprint only if a planned item is blocked without it, and otherwise the backlog. A follow-up of a follow-up needs Sam's word, and the ask names the chain. Sam can add to the order himself mid-sprint; that is a `planned` item, with his words on the ledger.

## Opening and closing

Opening a sprint means creating its directory, writing its `plan.md` from the order Sam agreed, moving the `current` symlink, and creating its milestone with the items' issues in it. Earlier sprints' directories are history, read only when a question needs them.

A sprint closes when every item is merged, dropped or rolled over. At the close the PM checks that anything the next sprint's engineers need to know has landed in `CLAUDE.md` or `docs/`, which is where knowledge lives between sprints; posts a short report card for Sam (items, days, review rounds, flakes fixed, what rolled over and why), each figure from a source that can be checked — the ledger, the milestone, the PRs' verdicts — and left out rather than estimated when its source cannot be read; and drafts the next work order for him.

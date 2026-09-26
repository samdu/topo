# How a change lands

One session coordinates; spawned engineers build; a janitor does the upkeep; two reviewers from another model family check the approach before any code exists and the code before it merges; Sam settles disagreements and holds the phone. Every hand-off is a written artefact — a plan, a ledger line, a PR description, a verdict, a janitor line — so no step depends on a context it cannot read, and the coordinator's recollection of what it dispatched is the least trusted thing here: the ledger and `git log` are what happened.

## The roles

- **buddy-prime**, the coordinator — Sam's own always-on session, in the cluster. It holds the roadmap (`docs/roadmap.md`), writes every plan and keeps its ledger, dispatches engineers, reads every review, settles every ambiguity rather than stalling, runs every device test with Sam, and decides every merge that the gate does not make by itself. It does not edit code: `.claude/hooks/pm-guard.py`, a project hook that applies to any session working in the main checkout on buddybox, denies `Edit`/`Write` on `Apps/`, `Packages/`, `Tests/`, `Womble/` and `project.yml` there (engineers edit in their own worktrees, which are other paths), and denies `Agent` with `fork` or an explicit `model`, so nothing spawned from the checkout runs at the coordinator's cost.
- **The janitor** — `scripts/janitor.py`, a script run every fifteen minutes on buddybox (`docs/janitor.md`). It merges what automerge left, reruns an infrastructure red once, republishes the install page, sweeps merged branches' worktrees, and reports to buddy-prime what needs a person: a blocking verdict, a stale draft, a green PR waiting on a device box, a PR nothing has touched. It decides nothing that needs judgement and says nothing to Sam.
- **Plan reviewer** — Codex on buddybox, Astra, run by the coordinator over `scripts/plan-review.sh`. Reads the plan, the repo and a curated slice of the memory wiki, read-only, and answers one question: *should it be built this way?* Wheels reinvented, indirect paths, complexity the design does not ask for.
- **Engineers** — one spawned session per plan on buddybox (`spawn-session buddybox <name> …`, Opus 5.5 with the Fable advisor beside it, per CLAUDE.md's *Ask the advisor at three moments*), each in its own worktree on a `buddy/<topic>` branch. Never an in-process agent: a coordinator that spawns engineers with the `Agent` tool hangs, and an engineer's work has to outlive the turn that started it. An engineer sees a plan and the repo; it never sees a review, only an amendment to the plan. From the fourth fix round the engineer is fresh and one effort tier up (`.claude/agents/topo-engineer-senior.md` is its definition), told how many attempts came before it.
- **CI reviewer** — Codex in `pr-validate.yaml`, Sol. Runs on every ready PR once the fast jobs are green and answers a different question: *does the code do what the description says, and does the evidence hold?*
- **Sam** — settles a plan disagreement, holds the phone for the rare device test, gives the word on a merge the reviewer could not judge, and owns design and maintainability judgement, which is the class of defect no reviewer catches at a useful rate.

## The plan

A plan opens with two sections, and a plan missing either goes back to the coordinator before any reviewer reads it.

- **Global Constraints** — the values the spec fixes, copied verbatim rather than paraphrased: sizes, timings, names, the invariants in CLAUDE.md's *Where the risk lives*. This is the reviewer's lens, and a violated constraint is Critical by definition, whatever else the change does well.
- **Review Focus** — the failure modes the spec implies that no task in the plan tests, each pinned to the test that would catch it. Prose about "be careful with X" is not a Review Focus entry; the pin is what makes it one.

The rest is what changes, why, and what proves it. The proof section is explicit about what is proved by the suite, what by the simulator, and what only a physical device can show.

## The ledger

One `progress.md` per plan, beside the plan (`~/Desktop/topo-plans/progress-<topic>.md`, on the Desktop syncthing carries to every host), append-only: nothing in it is ever edited or removed, because its whole value is that it is not a memory. It opens with two header lines and then carries one line per event, newest last, timestamps in UTC:

```
branch: buddy/stone-marks
plan: plan-stone-marks.md — Stone marks under the composer
- 2026-09-19T21:40Z stage: planned
- 2026-09-19T22:10Z stage: reviewed rounds=2
- 2026-09-19T22:20Z stage: building
- 2026-09-19T23:05Z task: the marks drawn from Look — 4f2a91c
- 2026-09-20T00:12Z fix: round 1, the well's hit area and the dimmed jewel — a13b7de
- 2026-09-20T00:30Z deferred: the draft row hard-codes its padding (Minor, round 1)
- 2026-09-20T00:41Z ruling: the mark stays mic.fill — why: the spec's glyph line — cost if wrong: one Look field later
- 2026-09-20T01:20Z merged: #112
```

The kinds are `stage:` (`planned`, `reviewed` with `rounds=N`, `building`), `task:`, `fix:`, `deferred:`, `ruling:`, `escalated:` and `merged:`, each ending in the commit SHA where there is one. The coordinator writes the line as the thing happens, not in a batch at the end, because the event a compaction eats is the one that was never written down.

After a compaction the ledger and `git log` are what the branch has done, and the coordinator's recollection is not evidence: work that is not in the ledger is work to check for in `git log` before dispatching it again. `.claude/hooks/ledger-recall.py` reads the tail of every ledger whose branch is unmerged back into a session in the checkout on a compaction and on a resume, so the memory arrives without being asked for.

The board reads the ledgers too (`wiki/team-pane.md`): the stage, the plan-review rounds and the rulings on a branch's row come from the file rather than from anything posted by hand, so a row is as current as the ledger and survives a restart of either side.

## The steps

1. **Plan.** The coordinator writes the plan, header sections first.
2. **Plan review.** The coordinator runs the plan reviewer. Its output has two classes: **red lines** (do not build it this way) and **suggestions** (take or leave). Three outcomes, none of which loops:
    - no notes → the plan goes to the engineer;
    - notes the coordinator agrees with → it fixes the plan and it goes to the engineer;
    - a red line the coordinator disagrees with → it puts it to Sam in its own thread; once settled, it fixes the plan and it goes to the engineer.
    Suggestions never escalate. A second review round is not run.
3. **Build.** The engineer implements on its branch, runs the Swift suites locally (a red suite means no PR), and opens the PR **as a draft**. The description is the contract: what was done, and a **Proof** section listing what was verified, as a checklist. Anything only a device can show is an unchecked box — `- [ ] device: …`. Every claim in it is exactly as strong as the code and the tests behind it: the reviewer reads the description literally, so an absolute — "every mutation", "nothing is written uncoordinated" — is a finding waiting for the one instance nobody grepped for, and a behaviour verified only on the device, or only by eye, is stated as that rather than as a property of the code. The engineer reports the PR to buddy-prime with `SendMessage`, and again at every boundary after: blocked, fixed, finished — what, where (branch, commit, PR), what it waits on. It never merges, never reads or answers a review, and never polls with background shells.
4. **Gate one — is this the right PR?** The coordinator reads the description against the plan. Not the code. A mismatch goes back to the engineer as a plan clarification; a disagreement about what the plan meant goes to Sam. When the description matches, the coordinator marks the PR ready for review. If the Proof section carries a device box, the coordinator installs the build over `devicectl` and runs the test with Sam first, then ticks the box; an unchecked box blocks the merge. A draft left untouched is what the janitor reports, since nothing runs on one.
5. **Mechanical tests.** Every push to the PR starts `pr-validate.yaml`: the harness self-tests, the package suites, Womble, Topo on the simulator (the UI tests behind the audio lane), and the build-only targets, as three parallel macOS jobs behind the one `test` gate. The real ear runs only when the diff touches the voice path, and nightly on main. The CI reviewer waits on `topo_unit` and `others` alone and runs while `topo_ui` is still going, so a verdict arrives minutes after a push rather than after the UI tests; a red fast job spends no reviewer round, and a red job of either kind holds the merge. A red that is the infrastructure's — a flaked suite job, a reviewer that never ran — the janitor reruns once; red again, it reports the failing jobs and tests.
6. **Gate two — does it do what it says?** The CI reviewer reads the description and the code. Every finding cites `path:line` or a concrete input that breaks the claim; a finding with neither is reported low-confidence and does not block. A blocking verdict goes to the **coordinator**, not the engineer — the janitor reports one the moment the run concludes, since a session on buddybox carries no channel that would deliver it — and the coordinator judges it against the plan and the ledger, and either sends the engineer a fix as an amendment to the plan or, if it disagrees, records a ruling. Engineers never argue with a reviewer.
7. **Merge.** Auto-merge squashes a ready PR whose validate run is green and whose description has no unchecked box; the janitor makes the same merge when automerge missed it. A PR whose reviewer could not run — `reviewer_ran` red, the suite green, and still so after the janitor's rerun — has no verdict, and merging it is Sam's word, given to the coordinator and made by it with the residue on the ledger. The coordinator writes `merged:` in the ledger with the PR number and picks the next plan.

## The fix loop

Findings are Critical, Important or Minor, and the severity decides whether the loop spends a round on them.

- **Critical** — a Global Constraint violated, or the change is unsafe or wrong as built.
- **Important** — a defect inside what the plan asked for.
- **Minor** — everything else: style, a neighbouring weakness, a better way to have done it. **A Minor finding never enters the loop.** It is reported, written to the ledger as `deferred:`, and handed to the sweep before merge. Rounds are spent on Critical and Important alone.

A fix round is scoped on both sides. The engineer fixes the listed findings on the same branch and says which commit answers which. The re-review (`scripts/review-prompt.sh`) is given its own earlier verdict and the PR's commits since, each with its patch, and first answers that list — each prior finding closed, still open or moot — then reads the whole PR again; a new finding in code the fix did not touch blocks only if it loses or corrupts a record, splits the primary, leaks a secret, or makes the description untrue at runtime, and from round 3 only a bug a real user would hit blocks at all. Everything else is reported non-blocking for the coordinator to file as an issue and write to the ledger as deferred, and does not extend the loop. That scoping is what makes the cap converge; without it a reviewer reading claims literally never runs out of instances.

The rounds themselves:

- **Rounds 1–3** resume the same engineer, which keeps its context and costs a message.
- **Round 4** is a fresh engineer one tier up, told plainly that three prior attempts failed, and to read the ledger and the last review before touching anything. A fourth round at the same tier is the tier's answer, not a new one.
- **After that**, Sam, with the findings weighed: an override (`gh pr merge --admin`, the residue filed as issues) or a decision to keep going.

Two blocking rounds in the same *class* of defect is its own signal, whatever the count: the class was never swept, so the coordinator runs an adversarial reviewer over the whole change and the engineer fixes what it reproduces, instead of taking the next instance one at a time. #93 took ten rounds that way, each finding one more mutation under "cancellation is checked before every mutation", and every round cost an hour of CI.

Rounds are counted on the pipeline board, so a loop that is going badly is visible before it is late.

## Dispatching a review

The coordinator's dispatch to a reviewer says what changed and what to read, and nothing about what to conclude. "Don't flag X", "at most Minor", "this is intentional so ignore it" are not in it, and `.claude/hooks/review-dispatch.py` refuses a dispatch that carries one.

A defect the plan itself mandated is still a defect: it is reported as Important, tagged `plan-mandated`, and adjudicated against the spec — often the plan was wrong. An implementer's rationale never downgrades a finding. Only the spec, or a ruling the coordinator recorded, does.

## Rulings

Where the plan and the spec do not settle a question, the coordinator decides and keeps going rather than stalling on Sam. Every decision is one ledger line — what was decided, why, and what it costs if it is wrong — and the rulings sit under that branch's row on the board.

This is also the only place pushback on a reviewer lives. The coordinator may overrule a finding, but only as a recorded ruling with its cost written down; an unrecorded disagreement is a fix round.

## The retro rule

A mechanical reviewer finding that turns up on a third branch stops being a reviewer's job. It becomes a lint or a CI check in `pr-validate.yaml` — or a line in CLAUDE.md's *Where the risk lives* if it is a judgement rather than a pattern. More reviewer prose is not the answer to something a grep can hold. The same rule runs the other way for upkeep: a thing the coordinator finds itself doing by hand on a third PR — a rerun, a merge the gate should have made, a publish — is the janitor's, as a rule with a test.

## Why this shape

- Approach defects are cheapest before code exists and are the class diff review misses, so the cross-family reviewer sits at the plan. Diff review is good at narrow functional defects, so that is all the CI reviewer is asked for.
- Reviews go to the coordinator because a worker answering a reviewer optimises for the reviewer's approval, not the design; the coordinator is the only reader who knows why the plan says what it says.
- The ledger exists because the coordinator is a session with a context window, and the expensive failure of a coordinator that has been compacted is re-dispatching finished work.
- The janitor exists because the expensive failure of a coordinator that is a session is ending a turn on a wake that never comes: a channel that stops after four rounds, a draft that runs no CI, a body edit that fires no merge. A script that looks every fifteen minutes needs no wake, and what it cannot decide it says to the session that can.
- The plan review does not loop and the code review does, because a plan is cheap to change and an opinion about it is one round's worth of value, while code that does not do what it says is a defect that has to be closed. The loop converges because it is scoped, capped, and spent only on Critical and Important.
- Escalating the model before the human is cheaper than escalating to Sam, and a fourth attempt at the same tier is the same attempt.
- The device test is rare and owned by the one step where a human is already present.

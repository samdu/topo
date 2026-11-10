# How a change lands

One session coordinates; spawned engineers build; a janitor does the upkeep; two reviewers from another model family check the approach before any code exists and the code before it merges; Sam settles disagreements and holds the phone. Every hand-off is a written artefact — a plan, a ledger line, a PR description, a verdict, a janitor line — so no step depends on a context it cannot read, and the coordinator's recollection of what it dispatched is the least trusted thing here: the ledger and `git log` are what happened.

## The roles

- **topo-coordinator**, the coordinator — a session of its own on toolbox, given to Topo alone so Sam's main thread stays cheap; Sam watches it from the sessions pane and talks to it there. It holds the roadmap (`docs/roadmap.md`), writes every plan and keeps its ledger, dispatches engineers, reads every review, settles every ambiguity rather than stalling, runs every device test with Sam, and decides every merge that the gate does not make by itself. It does not edit code: `.claude/hooks/pm-guard.py`, a project hook that applies to any session working in a main checkout of the repo, denies `Edit`/`Write` on `Apps/`, `Packages/`, `Tests/`, `Womble/` and `project.yml` there (engineers edit in their own worktrees, which are other paths), and denies `Agent` with `fork` or an explicit `model`, so nothing spawned from the checkout runs at the coordinator's cost.
- **The janitor** — `scripts/janitor.py`, a script run every fifteen minutes on buddybox (`docs/janitor.md`). It merges a ready PR that is green with every box ticked, reruns a reviewer that never ran once, republishes the install page, sweeps merged branches' worktrees, triages each new issue through Sonnet into a fixed list of actions (a label, a close as fixed by a commit on main, or a question for Sam), and reports to the coordinator what it did and what needs a person, once per change: a blocking verdict, a green PR waiting on a device box, a PR nothing has touched, an issue put to Sam. It ticks a device box that the results on its build's issue verify (*Device checks*). Outside that triage it decides nothing that needs judgement, and it says nothing to Sam.
- **Plan reviewer** — Codex on buddybox, Astra, run by the coordinator over `scripts/plan-review.sh`. Reads the plan, the repo and a curated slice of the memory wiki, read-only, and answers one question: *should it be built this way?* Wheels reinvented, indirect paths, complexity the design does not ask for.
- **Engineers** — one spawned session per plan on buddybox (`spawn-session buddybox <name> …`, Opus 5.5 with the Fable advisor beside it, per CLAUDE.md's *Ask the advisor at three moments*), each in its own worktree on a `buddy/<topic>` branch. Never an in-process agent: a coordinator that spawns engineers with the `Agent` tool hangs, and an engineer's work has to outlive the turn that started it. An engineer sees a plan and the repo; it never sees a review, only an amendment to the plan. The fix behind the fourth review is made by a fresh engineer one effort tier up (`.claude/agents/topo-engineer-senior.md` is its definition), told how many attempts came before it.
- **CI reviewer** — Codex in `pr-validate.yaml`, Sol. Runs on every ready PR once `test` is green, which is the suites having passed on buddybox at that commit, and answers a different question: *does the code do what the description says, and does the evidence hold?*
- **buddy-prime** — Sam's own always-on session. When Sam gives a device result or a word on a PR in his own thread, it relays it to the coordinator, quoting him; it coordinates nothing itself.
- **Sam** — settles a plan disagreement, holds the phone for the rare device test, gives the word on a merge the reviewer could not judge, and owns design and maintainability judgement, which is the class of defect no reviewer catches at a useful rate.

## The plan

A plan opens with two sections, and a plan missing either goes back to the coordinator before any reviewer reads it.

- **Global Constraints** — the values the spec fixes, copied verbatim rather than paraphrased: sizes, timings, names, the invariants in CLAUDE.md's *Where the risk lives*. This is the reviewer's lens, and a violated constraint is Critical by definition, whatever else the change does well.
- **Review Focus** — the failure modes the spec implies that no task in the plan tests, each pinned to the test that would catch it. Prose about "be careful with X" is not a Review Focus entry; the pin is what makes it one.

The rest is what changes, why, and what proves it. The proof section is explicit about what is proved by the suite, what by the simulator, and what only a physical device can show.

## The ledger

One `progress.md` per plan, beside the plan (`~/topo-plans/progress-<topic>.md`, in the `topo-plans` Syncthing folder shared between toolbox and buddybox only), append-only: nothing in it is ever edited or removed, because its whole value is that it is not a memory. It opens with two header lines and then carries one line per event, newest last, timestamps in UTC:

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
3. **Build.** The engineer implements on its branch, pushes with `scripts/validate-and-push.sh` — which runs the suites the commit needs on buddybox, pushes only a green commit and posts the result to it (`docs/testing.md`), so a red suite means no PR — and opens the PR **as a draft** on its first green commit, not its last: a branch that lives only on a Mac is seen by no janitor, no pane and no sweep, and work has been lost that way. What already runs in Daphne (samdu/daphne-assistant) is lifted as it stands, in the same PR as the feature that needs it, and changed only where Topo's architecture forces a change; it is not re-derived in stages, because every stage is a PR with its own suites and its own device round. Every later push goes the same way. Before reporting it, the engineer runs an adversarial reviewer over the whole PR with the plan's Review Focus as the bar, and fixes what it reproduces: that is Claude, not Codex, so the whole-PR read is spent on the budget that is not scarce, and Codex's first review finds a PR that has already had one. The description is the contract: what was done, and a **Proof** section listing what was verified, as a checklist. A PR that does an issue's work says `Fixes #N` in its description, so the merge closes the issue. Anything only a device can show is an unchecked box — `- [ ] device: …`, worded as *Device checks* says. Every claim in it is exactly as strong as the code and the tests behind it: the reviewer reads the description literally, so an absolute — "every mutation", "nothing is written uncoordinated" — is a finding waiting for the one instance nobody grepped for, and a behaviour verified only on the device, or only by eye, is stated as that rather than as a property of the code. The engineer reports the PR to topo-coordinator with `SendMessage`, and again at every boundary after: blocked, fixed, finished — what, where (branch, commit, PR), what it waits on. A report says a PR is testable, or that a build exists, only with the build number the publish printed and the issue it opened (*Device checks*); a final head with no build yet is reported as that, since a device box can be run only on a published build. It never merges, never reads or answers a review, and never polls with background shells.
4. **Gate one — is this the right PR?** The coordinator reads the description against the plan. Not the code. A mismatch goes back to the engineer as a plan clarification; a disagreement about what the plan meant goes to Sam. When the description matches and the engineer's report carries the adversarial pass, the coordinator marks the PR ready for review. A device box is not run here: it waits until the PR is final, after gate two (*Device checks*), and an unchecked box blocks the merge. A draft is the coordinator's alone: the reviewer waits for ready, and the janitor says nothing of one but a verdict that blocked its head and its device checks.
5. **Mechanical tests.** The suites run on buddybox before the push, not on a hosted runner: `scripts/validate-and-push.sh` runs the harness self-tests, the package suites, Womble, Topo on the simulator (the UI tests behind the audio lane), and the build-only targets, as suites, each only when the commit's paths need it (`docs/testing.md`), and posts each one's result to the commit as a status: a documentation change runs none of them and is still reviewed, a change to the harness alone runs the harness self-tests and no simulator, and a change to the app, a package the app links, the tests or the CI runs all three. The real ear runs only when the diff touches the voice path. Every push to the PR starts `pr-validate.yaml`, whose `test` job reads those statuses off the PR's head: a commit with a suite's status missing or failed is red there, holds the merge and spends no reviewer round. A reviewer chain red with the reviewer never having run, the janitor reruns once, the reviewer's job alone (`docs/janitor.md`); a red `test` is never rerun by it, since only a run on the Mac answers one.
6. **Gate two — does it do what it says?** The CI reviewer reads the description and the code. Every finding cites `path:line` or a concrete input that breaks the claim; a finding with neither is reported low-confidence and does not block. A blocking verdict goes to the **coordinator**, not the engineer — the janitor reports one the moment the run concludes, since a session on buddybox carries no channel that would deliver it — and the coordinator judges it against the plan and the ledger, and either sends the engineer a fix as an amendment to the plan or, if it disagrees, records a ruling. Engineers never argue with a reviewer.
7. **Merge.** A PR whose last box Sam has ticked merges then: nothing is pushed to it after his test, since his test is of that head and a push that touches what he tested asks him to test again. The janitor squashes a ready PR whose validate run is green and whose description has no unchecked box on its next pass, whoever ticked the last one (`docs/janitor.md`, step 1); no workflow merges. A PR whose reviewer could not run — `reviewer_ran` red, the suite green, and still so after the janitor's rerun — has no verdict and a red `review_gate`, which is a required check, so merging it is Sam's word, given to the coordinator and made by it past the check (`gh pr merge --admin`) with the residue on the ledger. The coordinator writes `merged:` in the ledger with the PR number and picks the next plan.

## Device checks

A `- [ ] device: …` box is a claim only a physical device can show. It is worded for a person holding the device: what to do there, and what they should then see. A box that wants more than one verification says how many, `- [ ] device(2): …`: the count sits in the box it governs, a box without one wants one, and both forms are unchecked boxes to the merge, so nothing about the merge gate reads the number.

Sam tests a PR once, when it is all ready. So a PR's device build is cut only once the PR is otherwise final:

- up to date with main: no conflict, and nothing on main since its base that touches what a box tests;
- every suite green at its head;
- its Codex round passed: ready, and its newest verdict not blocking;
- no further push planned, every finding it will take already taken.

`publish-topo.sh --dev` refuses a draft, a PR that conflicts with main, one with no Codex verdict or a blocking newest one, and a head whose suites have not all passed; what GitHub cannot show — main moving on what a box tests without a conflict, a push still planned — is the engineer's and the coordinator's to hold. Once Sam has ticked the box, the PR merges at the janitor's next pass (step 1).

When a PR, or several PRs at once, are final with device boxes to run:

1. **One dev build per PR.** `publish-topo.sh --dev <PR>` (the script `docs/install.md` describes under *Cutting a build*, from a GUI-session shell on buddybox) publishes the PR's head into that PR's own slot on the install page, leaving main's and every other PR's alone, and prints its build number and commit. It refuses a branch with no open PR, a PR that is not final as above, and a head that has not passed every suite the PR's paths require (the `test` check, or the statuses it reads when no `test` ran), so a build is always a final head on which every suite passed: PRs are checked each on its own build, never merged into a combined branch. The engineer cuts the build for its own PR, and opens its issue (step 2) straight after, since the issue is what holds Sam's device on that build against the next push.
2. **One issue for the build in samdu/topo-link**, titled `Build <number> (<commit>)`, which is how Topo and the janitor find it. It says what the build is (the ref, the PRs in it) and holds one section per box:

    ```markdown
    ## check: maps-links
    pr: samdu/topo#348 at f66a678
    box: in a reply on the phone, a tap on a `topo maps search` link opens Apple Maps on that search near the same place

    Ask Topo for coffee near you and tap the link in its reply. Maps should open on that search, around where you are.
    ```

    The name is lowercase letters, digits and hyphens. `pr:` is the PR and the head of it the build carried; `box:` is the box's text after `device:` or `device(N):`, character for character and spacing included (one space after either colon, as written above, and nothing after the last word), which is what ties the check to the box. Under those two lines the check is written out for the person holding the device, as steps, with what Topo runs in the guest and what needs a finger.
3. **The build and the issue go to Sam together.** An engineer reports both to the coordinator, which points Sam at them; nothing else is sent to him about the checks. On the device, Topo reads the issue and works through it with him (samdu/topo-link's `README.md` is Topo's side of this), answering each check with a comment of its own: `## result: <name>` as its first line, then directly under it `device:` (the model and the device's name) and `status: pass` or `status: fail`, then a blank line and what was run and seen. A check that could not be run is said in a plain comment with no result heading.
4. **The janitor ticks a box its results verify** (`docs/janitor.md`, step 8): as many respondents as the box asks for have a newest result that passes, and none has one that fails. A comment that reads as a result for the check and is not a whole pass is a fail, unless Sam calls it passed: then the engineer ticks the box by hand, quoting his words and the evidence beside it on the PR, and what the result left short becomes a follow-up PR with no device box. Respondents are counted apart by comment author and, for one author, by the device the result names, so Sam's phone and his iPad are two and the same phone answering twice is one. It ticks only while the PR's head is the one the build carried, and comments on the PR with the results it counted; a head that has moved since, or a check that failed, it reports to the coordinator, which decides: a fix and another build, or a tick by hand when what moved cannot bear on the box. A head that moved after the build is the case the rule above exists to prevent.
5. **Whoever opened the issue closes it** once every box it names is ticked or its PR is closed. A closed issue is no longer read, so its results tick nothing from then on, and an open one still speaks: a box unticked by hand is ticked again while its results stand.

## The fix loop

The shape the loop aims at is Sam's: most PRs are good first try (one review) or pass after one round of changes (two reviews), with a long tail out to a hard cap of four. Four Codex verdicts is that cap: `scripts/review-cap.sh` counts them as `scripts/review-prompt.sh` counts the round, at the start of a run and again immediately before a verdict is posted, the reviewer does not run a fifth time and no fifth verdict is posted, one comment on the PR says the cap is reached, and `review_gate` stays red, so nothing merges it by itself. It merges on Sam's word, or goes back to draft for a replan; the count is the PR's, so a replanned change is reviewed as a new PR.

Findings are Critical, Important or Minor, and the severity decides whether the loop spends a round on them.

- **Critical** — a Global Constraint violated, or the change is unsafe or wrong as built.
- **Important** — a defect inside what the plan asked for.
- **Minor** — everything else: style, a neighbouring weakness, a better way to have done it. **A Minor finding never enters the loop.** It is reported, written to the ledger as `deferred:`, and handed to the sweep before merge. Rounds are spent on Critical and Important alone.

A fix round is scoped on both sides. The engineer fixes the listed findings on the same branch and says which commit answers which. From round 2 the re-review (`scripts/review-prompt.sh`) sees only the fix diff and the list: it is given its own earlier verdict and the PR's commits since, each with its patch, first answers that list — each prior finding closed, still open or moot — then reviews the change since. Anything else it notices in code the fix did not touch is reported non-blocking, for the coordinator to file as an issue and write to the ledger as deferred, and does not extend the loop; from round 3 only a bug a real user would hit blocks at all. The whole-PR read belongs to round 1 and to the adversarial pass before it. That scoping is what makes the loop converge; a reviewer reading the whole PR's claims literally every round never runs out of instances.

The rounds themselves:

- **Rounds 2–3**: the fix behind each review resumes the same engineer, which keeps its context and costs a message.
- **Round 4**: the fix behind the last review is a fresh engineer one tier up, told plainly that three prior attempts failed, and to read the ledger and the last review before touching anything. A fourth attempt at the same tier is the tier's answer, not a new one.
- **After that**, the cap: Sam, with the findings weighed, either overrides (`gh pr merge --admin`, the residue filed as issues) or sends the PR back to draft for a replan. A capped PR with device boxes is tested before he decides, and no fifth verdict ever comes to make it final, so once its head is past the commit the last verdict read and that verdict's findings are fixed, the coordinator labels it `final-at-cap`: `topo-final-gate.sh` takes the label, with the cap's comment and a head past that commit, in place of a passing verdict, and its build can be cut (*Device checks*).

Two blocking rounds in the same *class* of defect is its own signal, whatever the count: the class was never swept, so the coordinator runs an adversarial reviewer over the whole change and the engineer fixes what it reproduces, instead of taking the next instance one at a time. #93 took ten rounds that way, each finding one more mutation under "cancellation is checked before every mutation", and every round cost an hour of suites.

Rounds are counted on the pipeline board, so a loop that is going badly is visible before it is late.

## Dispatching a review

The coordinator's dispatch to a reviewer says what changed and what to read, and nothing about what to conclude. "Don't flag X", "at most Minor", "this is intentional so ignore it" are not in it, and `.claude/hooks/review-dispatch.py` refuses a dispatch that carries one: an `adversarial-reviewer` agent's prompt, or a Bash command whose text, with its line continuations joined and its quotes and backslashes taken out, names `plan-review.sh`, or `codex` with `exec`, its alias `e` or `review` later on the same line (case-sensitive, so prose about "the Codex reviewer" is not it), which is read whole. Steering is read in that text and again with its quotes and backslashes taken out, so a quote splitting a phrase (`do not "flag"`) does not hide it. It parses no shell, so prose that names the invocation is read too, and a name put together as the command runs is not; writing about the invocation itself goes through a file or the Write tool. A passage the dispatch quotes word for word from CLAUDE.md, the bar the reviewer reads anyway, is not steering when the sentence or quoted string holding it is CLAUDE.md's and runs 20 characters past it on each side, and nor is a sentence citing a recorded ruling with its date, the one thing that settles a finding in advance.

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
- The janitor exists because the expensive failure of a coordinator that is a session is ending a turn on a wake that never comes: a channel that stops after four rounds, a body edit that fires no merge. A script that looks every fifteen minutes needs no wake, and what it cannot decide it says to the session that can.
- The plan review does not loop and the code review does, because a plan is cheap to change and an opinion about it is one round's worth of value, while code that does not do what it says is a defect that has to be closed. The loop converges because it is scoped, capped, and spent only on Critical and Important.
- Codex is the scarce reviewer: its rounds come out of a weekly quota. So the whole-PR read that finds most defects is Claude's, before the PR is ready, and Codex's rounds after the first read only the fix.
- Escalating the model before the human is cheaper than escalating to Sam, and a fourth attempt at the same tier is the same attempt.
- The device test is rare and owned by the one step where a human is already present. Its results are written where a script can count them because Sam relaying a phone's output by hand is the slowest hop in the pipeline, and a box ticked from a count needs no session awake to tick it.

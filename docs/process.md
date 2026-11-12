# How a change lands

One manager session, the Topo PM, runs the sprint; an engineer owns each PR from its first commit to its merge; a janitor does the upkeep; Codex, a reviewer from another model family, reads the code before it merges; Sam settles what is his and holds the phone. Every hand-off is a written artefact — a work order, a ledger line, a PR description, a verdict, a janitor line — so no step depends on a context it cannot read, and a session's recollection of what it did is the least trusted thing here: the ledger and `git log` are what happened.

## The roles

- **The Topo PM** (`topo-pm`) — a session in its own cluster agent pod, reached through `daphne`'s bridge; Sam watches it from the sessions pane and the decisions pane. It owns the sprint (`docs/sprints.md`): the work order and the ledger, up to three sprint engineers and one ad-hoc engineer at a time on buddybox, which Mac tests what, scope calls on follow-up work, the ruling when an engineer's review rounds run out, the arbitration of a test said to be flaky, and the decision cards that put to Sam what is his. It holds the roadmap (`docs/roadmap.md`). It does not edit code; engineers do. Its brief is `~/topo-plans/sprints/current/brief.md`.
- **The janitor** — `scripts/janitor.py`, a script run every fifteen minutes on buddybox (`docs/janitor.md`). It merges a ready PR that is green with every box ticked, reruns a reviewer that never ran once, republishes the install page, sweeps merged branches' worktrees, triages each new issue through Sonnet into a fixed list of actions (a label, a close as fixed by a commit on main, or a question for Sam), and reports to the PM what it did and what needs a person, once per change: a blocking verdict, a PR at the review cap, a green PR waiting on a device box, a PR nothing has touched, an issue put to Sam. It ticks a device box that the results on its build's issue verify (*Device checks*). Outside that triage it decides nothing that needs judgement, and it says nothing to Sam.
- **Engineers** — one session per work-order item on buddybox (`spawn-session buddybox <name> "<brief>" --model opus --effort medium --cwd /Users/buddy/github/topo`, Opus 5.5 with the Fable advisor beside it, per CLAUDE.md's *Ask the advisor at three moments*), each in its own worktree on a `buddy/<topic>` branch. Never an in-process agent: an engineer's work has to outlive the turn that started it. Its brief names the item, what done means, and the files and docs worth reading, and carries no conclusion about how to build it. It owns its PR from first commit to merge: it plans where the item needs a plan, builds, validates, opens the draft, marks it ready, reads Codex's verdict, fixes what is right and marks it ready again, and cuts the device build when there is one. A session that has shipped a PR takes no further item: the next one goes to a fresh session.
- **CI reviewer** — Codex in `pr-validate.yaml`, Sol. Runs on every ready PR once `test` is green, which is the suites having passed on buddybox at that commit, and answers one question: *does the code do what the description says, and does the evidence hold?* `scripts/plan-review.sh` puts Codex (Astra) a different question over a plan before code exists — *should it be built this way?* — and is a tool an engineer may reach for, not a step.
- **buddy-prime** — Sam's own always-on session. When Sam gives a device result or a word on a PR in his own thread, it relays it to the PM, quoting him. It makes the admin merges the PM asks for, pinned to the head the PM names (*Merge*); it coordinates nothing itself.
- **Sam** — sets the sprint's work order, holds the phone for a device test, answers the PM's cards (a PR that cannot pass, spending, anything irreversible, anything that changes the sprint's size), and owns design and maintainability judgement, which is the class of defect no reviewer catches at a useful rate.

## When an engineer reports

An engineer tells the PM, with `SendMessage`, in three cases, and in each says what, where (branch, commit, PR) and what it waits on:

- **Its review rounds are used up** (*When the rounds run out*), with the findings still open.
- **It believes a test is flaky or environmental** (*A test that fails*), with the run and the commit.
- **It has found work outside its PR** (*Follow-up work*), with what it found and where.

And once more when a device build is cut (*Device checks*), since the build and its issue reach Sam through the PM's card. Nothing else is reported: a red suite its PR broke is its own to fix, a blocking verdict its own to answer, and a merge the janitor's to make. Between those it keeps going, and it never polls with background shells: a wait on something it does not own is a `Monitor` with an `until` loop.

## The plan

An item that is already built and owes only validation and a review needs no plan. Any other item gets one from its engineer, scaled to the item, written before the code and given to the engineer's advisor before the build starts. A plan opens with two sections:

- **Global Constraints** — the values the spec fixes, copied verbatim rather than paraphrased: sizes, timings, names, the invariants in CLAUDE.md's *Where the risk lives*. This is the reviewer's lens, and a violated constraint is Critical by definition, whatever else the change does well.
- **Review Focus** — the failure modes the spec implies that no task in the plan tests, each pinned to the test that would catch it. Prose about "be careful with X" is not a Review Focus entry; the pin is what makes it one.

The rest is what changes, why, and what proves it. The proof section is explicit about what is proved by the suite, what by the simulator, and what only a physical device can show. A plan question the spec and the item do not settle goes to the PM, who rules (*Rulings*).

## The steps

1. **Build.** The engineer implements on its branch, pushes with `scripts/validate-and-push.sh` — which runs the suites the commit needs on buddybox, pushes only a green commit and posts the result to it (`docs/testing.md`), so a red suite means no PR — and opens the PR **as a draft** on its first green commit, not its last: a branch that lives only on a Mac is seen by no janitor, no pane and no sweep, and work has been lost that way. What already runs in Daphne (samdu/daphne-assistant) is lifted as it stands, in the same PR as the feature that needs it, and changed only where Topo's architecture forces a change; it is not re-derived in stages, because every stage is a PR with its own suites and its own device round. Every later push goes the same way. The description is the contract: what was done, and a **Proof** section listing what was verified, as a checklist. A PR that does an issue's work says `Fixes #N` in its description, so the merge closes the issue. Anything only a device can show is an unchecked box — `- [ ] device: …`, worded as *Device checks* says. Every claim in it is exactly as strong as the code and the tests behind it: the reviewer reads the description literally, so an absolute — "every mutation", "nothing is written uncoordinated" — is a finding waiting for the one instance nobody grepped for, and a behaviour verified only on the device, or only by eye, is stated as that rather than as a property of the code.
2. **The adversarial pass.** Before its first ready, an engineer whose change touches an area CLAUDE.md's *Where the risk lives* names runs an adversarial reviewer over the whole PR, with the plan's Review Focus as the bar, and fixes what it reproduces: that is Claude, not Codex, so the whole-PR read is spent on the budget that is not scarce, and Codex's first review finds a PR that has already had one. Elsewhere — a test-only change, a docs change — it is the engineer's call, since Codex is the review.
3. **Ready.** The engineer marks the PR ready (`gh pr ready <n>`) when it is validated and its description is final: the ready transition is the request for a review, and each one spends a round of the cap. A draft is its engineer's: the reviewer waits for ready, and the janitor says nothing of one but a verdict that blocked its head and its device checks.
4. **Mechanical tests.** The suites run on buddybox before the push, not on a hosted runner: `scripts/validate-and-push.sh` runs the harness self-tests, the package suites, Womble, Topo on the simulator (the UI tests behind the audio lane), and the build-only targets, as suites, each only when the commit's paths need it (`docs/testing.md`), and posts each one's result to the commit as a status: a documentation change runs none of them and is still reviewed, a change to the harness alone runs the harness self-tests and no simulator, and a change to the app, a package the app links, the tests or the CI runs all three. The real ear runs only when the diff touches the voice path. Every push to the PR starts `pr-validate.yaml`, whose `test` job reads those statuses off the PR's head: a commit with a suite's status missing or failed is red there, holds the merge and spends no reviewer round. A reviewer chain red with the reviewer never having run, the janitor reruns once, the reviewer's job alone (`docs/janitor.md`); a red `test` is never rerun by it, since only a run on the Mac answers one.
5. **Review.** The CI reviewer reads the description and the code and posts its verdict on the PR (a comment under `<!-- agent-review: codex -->`, which the `githubpr` channel delivers to the session that opened the PR). Every finding cites `path:line` or a concrete input that breaks the claim; a finding with neither is reported low-confidence and does not block. A blocking verdict puts the PR back to draft. The engineer reads it, fixes every finding that is right in one batch on the same branch, says which commit answers which, resolves the review threads it fixed, and marks the PR ready again for the next round. A finding it judges wrong it does not fix, and it does not argue with the reviewer on the PR: if the finding still blocks when the rounds run out, it goes to the PM with the rest, with the engineer's reasoning.
6. **Merge.** A PR whose last box Sam has ticked merges then: nothing is pushed to it after his test, since his test is of that head and a push that touches what he tested asks him to test again. The janitor squashes a ready PR whose validate run is green and whose description has no unchecked box on its next pass, whoever ticked the last one (`docs/janitor.md`, step 1); no workflow merges. Two kinds of PR it leaves: one that changes what PR validate runs from the PR's own copy (`.github/`, `scripts/review-*`, `scripts/ci-select-*`), whose green run is no evidence, and one the PM has ruled merges as it stands past a red `review_gate` (*When the rounds run out*), including a PR whose reviewer could not run even after the janitor's rerun. For either, the engineer tells the PM once its review is clean, and the PM asks buddy-prime for an admin merge pinned to the reviewed head (`gh pr merge --admin --match-head-commit <sha>`), with the ruling, its reason and the open findings' destination on the ledger. A PR that cannot merge as it stands is a card for Sam.

## A test that fails

A red suite is read one of two ways:

- **The PR broke it.** The engineer fixes it. Nothing reaches the PM.
- **The engineer believes it is flaky or environmental.** It says so to the PM, which is the arbiter and does not take its word: the evidence is the same test passing on a rerun of the same commit, or failing on main. The PM investigates, or has an investigator do it, and rules. Flaky: a fixer is dispatched at once, outside the cap of three sprint engineers, and the PR reruns once the fix lands. Not flaky: it goes back to the engineer as a real failure.

## Device checks

A `- [ ] device: …` box is a claim only a physical device can show. It is worded for a person holding the device: what to do there, and what they should then see. A box that wants more than one verification says how many, `- [ ] device(2): …`: the count sits in the box it governs, a box without one wants one, and both forms are unchecked boxes to the merge, so nothing about the merge gate reads the number.

Sam tests a PR once, when it is all ready. So a PR's device build is cut only once the PR is otherwise final:

- up to date with main: no conflict, and nothing on main since its base that touches what a box tests;
- every suite green at its head;
- its Codex round passed: ready, and its newest verdict not blocking;
- no further push planned, every finding it will take already taken.

`publish-topo.sh --dev` refuses a draft, a PR that conflicts with main, one with no Codex verdict or a blocking newest one, and a head whose suites have not all passed; what GitHub cannot show — main moving on what a box tests without a conflict, a push still planned — is the engineer's to hold. Once Sam has ticked the box, the PR merges at the janitor's next pass (step 1).

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
3. **The build and the issue go to Sam together.** The engineer tells the PM the build number the publish printed and the issue it opened, and the PM posts a card for Sam with the install link and the issue; nothing else is sent to him about the checks. A final head with no build yet is reported as that, since a device box can be run only on a published build. On the device, Topo reads the issue and works through it with him (samdu/topo-link's `README.md` is Topo's side of this), answering each check with a comment of its own: `## result: <name>` as its first line, then directly under it `device:` (the model and the device's name) and `status: pass` or `status: fail`, then a blank line and what was run and seen. A check that could not be run is said in a plain comment with no result heading. The engineer keeps its session while the PR waits for Sam, and takes the fix if his test fails.
4. **The janitor ticks a box its results verify** (`docs/janitor.md`, step 8): as many respondents as the box asks for have a newest result that passes, and none has one that fails. A comment that reads as a result for the check and is not a whole pass is a fail, unless Sam calls it passed: then the engineer ticks the box by hand, quoting his words and the evidence beside it on the PR, and what the result left short becomes a follow-up item with no device box. Respondents are counted apart by comment author and, for one author, by the device the result names, so Sam's phone and his iPad are two and the same phone answering twice is one. It ticks only while the PR's head is the one the build carried, and comments on the PR with the results it counted; a head that has moved since, or a check that failed, it reports to the PM, and the engineer takes it: a fix and another build, or a tick by hand when what moved cannot bear on the box. A head that moved after the build is the case the rule above exists to prevent.
5. **Whoever opened the issue closes it** once every box it names is ticked or its PR is closed. A closed issue is no longer read, so its results tick nothing from then on, and an open one still speaks: a box unticked by hand is ticked again while its results stand.

## The fix loop

The shape the loop aims at is Sam's: most PRs are good first try (one review) or pass after one round of changes (two reviews). Three Codex verdicts is the cap: `scripts/review-cap.sh` counts them as `scripts/review-prompt.sh` counts the round, at the start of a run and again immediately before a verdict is posted; at the cap the reviewer does not run again and no further verdict is posted, one comment on the PR says the cap is reached, and `review_gate` stays red, so nothing merges it by itself. The PR's `second-chance` label raises the cap to five (*When the rounds run out*). The count is the PR's, so work taken out of it is reviewed as a new PR.

Findings are Critical, Important or Minor, and the severity decides whether the loop spends a round on them.

- **Critical** — a Global Constraint violated, or the change is unsafe or wrong as built.
- **Important** — a defect inside what the item asked for.
- **Minor** — everything else: style, a neighbouring weakness, a better way to have done it. **A Minor finding never enters the loop.** It is reported, written to the ledger as deferred, and goes where *Follow-up work* sends it. Rounds are spent on Critical and Important alone.

A fix round is scoped on both sides. The engineer fixes the listed findings on the same branch and says which commit answers which. From round 2 the re-review (`scripts/review-prompt.sh`) sees only the fix diff and the list: it is given its own earlier verdict and the PR's commits since, each with its patch, first answers that list — each prior finding closed, still open or moot — then reviews the change since. Anything else it notices in code the fix did not touch is reported non-blocking, for the engineer to hand the PM as work outside its PR, and does not extend the loop; from round 3 only a bug a real user would hit blocks at all, and that holds for rounds 4 and 5 of a second chance too. The whole-PR read belongs to round 1 and to the adversarial pass before it. That scoping is what makes the loop converge; a reviewer reading the whole PR's claims literally every round never runs out of instances.

Two blocking rounds in the same *class* of defect is its own signal, whatever the count: the class was never swept, so the engineer runs an adversarial reviewer over the whole change and fixes what it reproduces, instead of taking the next instance one at a time. #93 took ten rounds that way, each finding one more mutation under "cancellation is checked before every mutation", and every round cost an hour of suites.

## When the rounds run out

If the third verdict still blocks, the engineer stops — it pushes nothing more and does not mark the PR ready — and tells the PM, with the findings still open. The PM rules, and writes the ruling to the ledger with its reason:

1. **This engineer, now.** A second chance on the same PR: the PM labels it `second-chance`, and the engineer fixes and marks it ready again. The label raises the cap from three to five; `review-cap.sh` reads it as present or absent, so a PR has one second chance and no more, however often the label is put on. Labelling starts no run: the engineer's next ready transition does.
2. **Someone else, this sprint.** The PR merges as it stands (*Merge*), and the open findings become a new item on this sprint's work order.
3. **Someone else, someday.** The PR merges as it stands, and the open findings become a backlog issue.
4. **A card for Sam.** The PR is held.

A PR whose second chance still ends blocked is a card for Sam, and so is any PR that cannot merge as it stands. A capped PR with device boxes is tested before it merges, and no further verdict ever comes to make it final, so once its head is past the commit the last verdict read and that verdict's findings are fixed, the PM labels it `final-at-cap`: `topo-final-gate.sh` takes the label, with the cap's comment and a head past that commit, in place of a passing verdict, and its build can be cut (*Device checks*).

## Follow-up work

Work found outside a PR's scope — by an engineer, a review or the PM — goes to one of three places, and the PM decides which: into the PR, only if the PR cannot be correct without it; a new item this sprint, only if a planned item is blocked without it; or the backlog, everything else. A follow-up of a follow-up needs Sam's word. This is the rule that keeps a sprint the size he agreed (`docs/sprints.md`).

## Dispatching a review

A dispatch to a reviewer says what changed and what to read, and nothing about what to conclude. "Don't flag X", "at most Minor", "this is intentional so ignore it" are not in it, and `.claude/hooks/review-dispatch.py` refuses a dispatch that carries one: an `adversarial-reviewer` agent's prompt, or a Bash command whose text, with its line continuations joined and its quotes and backslashes taken out, names `plan-review.sh`, or `codex` with `exec`, its alias `e` or `review` later on the same line (case-sensitive, so prose about "the Codex reviewer" is not it), which is read whole. Steering is read in that text and again with its quotes and backslashes taken out, so a quote splitting a phrase (`do not "flag"`) does not hide it. It parses no shell, so prose that names the invocation is read too, and a name put together as the command runs is not; writing about the invocation itself goes through a file or the Write tool. A passage the dispatch quotes word for word from CLAUDE.md, the bar the reviewer reads anyway, is not steering when the sentence or quoted string holding it is CLAUDE.md's and runs 20 characters past it on each side, and nor is a sentence citing a recorded ruling with its date, the one thing that settles a finding in advance.

A defect the plan itself mandated is still a defect: it is reported as Important, tagged `plan-mandated`, and adjudicated against the spec — often the plan was wrong. An implementer's rationale never downgrades a finding. Only the spec, or a ruling the PM recorded, does.

## Rulings

Where the item, the plan and the spec do not settle a question, the PM decides and keeps going rather than stalling on Sam. Every decision is one ledger line — what was decided, why, and what it costs if it is wrong. This is also the only place pushback on a reviewer lives: a finding is overruled only as a recorded ruling with its cost written down.

## The retro rule

A mechanical reviewer finding that turns up on a third branch stops being a reviewer's job. It becomes a lint or a CI check in `pr-validate.yaml` — or a line in CLAUDE.md's *Where the risk lives* if it is a judgement rather than a pattern. More reviewer prose is not the answer to something a grep can hold. The same rule runs the other way for upkeep: a thing the PM finds itself doing by hand on a third PR — a rerun, a merge the gate should have made, a publish — is the janitor's, as a rule with a test.

## Why this shape

- The engineer answers its own review because it holds the context the fix needs: a relay through a manager costs a hop per round and loses what the engineer knew. What keeps it from optimising for the reviewer's approval over the design is the cap, the scoping of each round, and the PM's ruling when the rounds run out.
- The ledger exists because the PM is a session with a context window, and the expensive failure of one that has been compacted is re-dispatching finished work.
- The janitor exists because the expensive failure of a session is ending a turn on a wake that never comes: a channel that stops at the cap, a body edit that fires no merge. A script that looks every fifteen minutes needs no wake, and what it cannot decide it says to the session that can.
- The code review loops because code that does not do what it says is a defect that has to be closed, and it converges because it is scoped, capped, and spent only on Critical and Important.
- Codex is the scarce reviewer: its rounds come out of a weekly quota. So the whole-PR read that finds most defects is Claude's, before the PR is ready, where the risk warrants it, and Codex's rounds after the first read only the fix.
- A second chance goes to the same engineer because a fresh one starts without the context the rounds built; a third chance is not offered because a PR that two more rounds could not close is a question for Sam, not for another round.
- The device test is rare and owned by the one step where a human is already present. Its results are written where a script can count them because Sam relaying a phone's output by hand is the slowest hop in the pipeline, and a box ticked from a count needs no session awake to tick it.

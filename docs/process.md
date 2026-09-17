# How a change lands

One persistent session plans and judges; workers build; two reviewers from another model family check the approach before any code exists and the code before it merges; Sam settles disagreements and holds the phone. Every hand-off is a written artefact — a plan, a PR description, a verdict — so no step depends on a context it cannot read.

## The roles

- **Topo PM** — one long-lived Claude session (Fable, medium effort) on buddybox. It holds the design, writes every plan, reads every review, runs every device test, and decides every merge. It does not edit code: a hook denies it `Edit`/`Write` on `Apps/`, `Packages/`, `Tests/`, `Womble/` and `project.yml`, and it never forks itself or names a model when it delegates, so nothing it spawns runs at its own cost. What it spends is the brief, three short reports and the phone conversation.
- **Plan reviewer** — Codex on buddybox, Astra, run by the PM over `scripts/plan-review.sh`. Reads the plan, the repo and a curated slice of the memory wiki, read-only, and answers one question: *should it be built this way?* Wheels reinvented, indirect paths, complexity the design does not ask for.
- **Engineers** — `general-purpose` agents (Opus, medium), one per plan, each in its own worktree on a `buddy/<topic>` branch. An engineer sees a plan and the repo; it never sees a review.
- **CI reviewer** — Codex in `pr-validate.yaml`, Sol. Runs on every ready PR once the mechanical suite is green and answers a different question: *does the code do what the description says, and does the evidence hold?*
- **Sam** — settles a plan disagreement, holds the phone for the rare device test, and owns design and maintainability judgement, which is the class of defect no reviewer catches at a useful rate.

## The steps

1. **Plan.** The PM writes the plan: what changes, why, what proves it. The proof section is explicit about what is proved by the suite, what by the simulator, and what only a physical device can show.
2. **Plan review.** The PM runs the plan reviewer. Its output has two classes: **red lines** (do not build it this way) and **suggestions** (take or leave). Three outcomes, none of which loops:
    - no notes → the plan goes to the engineer;
    - notes the PM agrees with → the PM fixes the plan and it goes to the engineer;
    - a red line the PM disagrees with → the PM puts it to Sam in its own thread; once settled, the PM fixes the plan and it goes to the engineer.
    Suggestions never escalate. A second review round is not run.
3. **Build.** The engineer implements on its branch, runs the Swift suites locally (a red suite means no PR), and opens the PR **as a draft**. The description is the contract: what was done, and a **Proof** section listing what was verified, as a checklist. Anything only a device can show is an unchecked box — `- [ ] device: …`.
4. **Gate one — is this the right PR?** The PM reads the description against the plan. Not the code. A mismatch goes back to the engineer as a plan clarification; a disagreement about what the plan meant goes to Sam. When the description matches, the PM marks the PR ready for review. If the Proof section carries a device box, the PM installs the build over `devicectl` and runs the test with Sam first, then ticks the box; an unchecked box blocks auto-merge.
5. **Mechanical tests.** Ready-for-review starts `pr-validate.yaml`: the harness self-test, the package suites, Womble and Topo on the simulator behind the audio lane, and the build-only targets. Nothing downstream runs on a red suite.
6. **Gate two — does it do what it says?** The CI reviewer reads the description and the code. Every finding cites `path:line` or a concrete input that breaks the claim; a finding with neither is reported low-confidence and does not block. A blocking verdict goes to the **PM**, not the engineer: the PM judges it against the plan, and either sends the engineer a fix as an amendment to the plan or, if it disagrees, takes it to Sam. Engineers never argue with a reviewer.
7. **Merge.** Auto-merge squashes a ready PR whose validate run is green and whose description has no unchecked box. The PM records what landed against its plan and picks the next one.

## Why this shape

- Approach defects are cheapest before code exists and are the class diff review misses, so the cross-family reviewer sits at the plan. Diff review is good at narrow functional defects, so that is all the CI reviewer is asked for.
- Reviews go to the PM because a worker answering a reviewer optimises for the reviewer's approval, not the design; the PM is the only reader who knows why the plan says what it says.
- Nothing loops. Each review has one round and three exits, and the exits all end at the engineer.
- The device test is rare and owned by the one step where a human is already present.

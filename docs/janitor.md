# The janitor

The mechanical upkeep of the pipeline: `scripts/janitor.py`, one pass every fifteen minutes on buddybox as `buddy`, in the GUI session so it has the login keychain the OTA build signs with. It is a script and not a session: every decision is a function of what it read, every action is a `gh`, `git`, `tmux` or shell call, and `--dry-run` prints the pass instead of running it. It reads no review, merges over no red or missing verdict, edits no code, and says nothing to Sam.

## What a pass does

1. **Merges what automerge left.** A ready PR on `main` whose newest `pull_request` validate run is green, whose description has no unchecked box, and that carries the `automerge` label when the repository's `AUTOMERGE_REQUIRE_LABEL` says one is needed — the same conditions `automerge.yaml` merges on — still unmerged fifteen minutes after the run concluded, is squash-merged pinned to the head the green run was read for (`--match-head-commit`). Automerge misses a PR when its `workflow_run` event is dropped or when the last change was to the description alone; the janitor is the backstop, not a second policy. A label rule it cannot read merges nothing and is reported.
2. **Reruns an infrastructure red once.** A validate run red because a suite job (`test`) failed, or because the reviewer never ran (`reviewer_ran` red with the suite green: Codex out of quota, a login gone stale), has its failed jobs rerun once per head, ten minutes after it concluded and only when no run is in progress for that head. Red again after that, it is reported with the failing jobs and, for a suite job, the failing tests read off the log. A red `review_gate` with the reviewer having run is a verdict, never rerun.
3. **Republishes the install page** when the commit in its `version.json` is not origin/main's, by running `publish-topo.sh origin/main` from the `ota` experiment in samdu/experiments. A failed publish is reported with the tail of its log and tried again after two hours; a successful one is not tried again for that commit inside the same window, since the page lags the pod bounce by a minute.
4. **Sweeps worktrees.** A linked worktree of the main checkout on a `buddy/*` branch whose PR merged more than a day ago is removed, after any tmux session whose pane sits in it is killed; the local branch goes with it. A worktree that will not remove (uncommitted changes) is reported and left. Detached worktrees, and the checkout itself, are never touched.
5. **Reports what needs a person**, once per condition per head and again every three hours while it holds: a verdict that blocks (the review is on the PR, and the session that opened it may not carry the channel that would deliver it); a draft untouched for fifteen minutes (CI and the reviewer never run on a draft); a green PR with Proof boxes unticked; a ready PR with no validate run; a run cancelled with nothing after it; and a PR nothing has touched for forty-five minutes while no run is in progress, with the run's conclusion and its red jobs.

Thresholds are constants at the top of the script (`GRACE`, `SETTLE`, `IDLE`, `REPEAT`, `SWEEP`, `PUBLISH_RETRY`).

## Where the report goes

One message per pass that did or found anything, from `topo-janitor` into **buddy-prime**, through the mesh socket buddybox's bridge registers for that peer under `~/.claude/sessions/` — the same envelope `SendMessage` writes, so it arrives as a turn from a peer. A quiet pass sends nothing. A report that cannot be delivered (no live registration, a socket that refuses) is kept in the state file and sent at the front of the next one. buddy-prime is the coordinator (`docs/process.md`): what it does with a line is its judgement, and nothing here reaches Sam directly.

## State

`~/.local/state/topo-janitor/state.json`: which report keys fired and when, which heads have had their rerun, each publish attempt by commit with its outcome, and the undelivered lines. Keys for heads no open PR carries are dropped at the end of each pass.

## Running it

The LaunchAgent `zone.hexagon.topo-janitor` (dotfiles, installed by `setup.sh` on buddybox) runs `tools/topo-janitor` every fifteen minutes: it fetches origin and runs `scripts/janitor.py` as it is on origin/main, so the janitor is never the checkout's stale copy and never edits the checkout. By hand:

```sh
scripts/janitor.py --dry-run --verbose    # decide everything, run nothing, print the report
scripts/janitor.py                        # one pass
```

`scripts/tests/janitor-test.sh` holds the decisions over scripted readings and one whole pass against a fake `gh`, `git`, `tmux` and `curl`, in the PR check.

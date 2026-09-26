# The janitor

The mechanical upkeep of the pipeline: `scripts/janitor.py`, one pass every fifteen minutes on buddybox as `buddy`, in the GUI session so it has the login keychain the OTA build signs with. It is a script and not a session: every decision is a function of what it read, every action is a `gh`, `git`, `tmux` or shell call, and `--dry-run` prints the pass instead of running it. It reads no review, merges over no red or missing verdict, edits no code, and says nothing to Sam.

## What a pass does

1. **Merges what automerge left.** A ready PR on `main` whose newest `pull_request` validate run is green, whose description has no unchecked box, and that carries the `automerge` label when the repository's `AUTOMERGE_REQUIRE_LABEL` says one is needed — the same conditions `automerge.yaml` merges on — still unmerged fifteen minutes after the run concluded, is squash-merged pinned to the head the green run was read for (`--match-head-commit`). Automerge misses a PR when its `workflow_run` event is dropped or when the last change was to the description alone; the janitor is the backstop, not a second policy. A label rule it cannot read merges nothing and is reported.
2. **Reruns an infrastructure red once.** A validate run red because a suite job (`topo_unit`, `topo_ui`, `others`) failed outside its tests — at a setup, lane or upload step (`SETUP_STEPS` in the script: booting the simulator, the audio lane, a model cache, the checkout action), or with no failed step at all, which is a runner lost — or because the reviewer never ran (`reviewer_ran` red with every suite job green: Codex out of quota, a login gone stale), has its failed jobs rerun once per head, ten minutes after it concluded and only when no run is in progress for that head. A suite job whose build, tests or script tests failed is the code's and is never rerun, whatever the other jobs did; it is reported as idle in time. Red again after the one rerun, the run is reported with its failing jobs and, for a suite job, the failing tests read off the log. A red `review_gate` with the reviewer having run is a verdict, never rerun.
3. **Republishes the install page** when the commit in its `version.json` is not origin/main's, by running `publish-topo.sh origin/main` from the `ota` experiment in samdu/experiments. A failed publish is reported with the tail of its log and tried again after two hours; a successful one is not tried again for that commit inside the same window, since the page lags the pod bounce by a minute.
4. **Sweeps worktrees.** A linked worktree of the main checkout is removed when its branch has no open PR, its tip is exactly the head a PR on that branch was merged at, that merge is more than a day old, and `git status` in it is clean. A reused branch name (an older PR merged at another head, a newer one open) and a tip with commits past the merged head both match nothing. The clean check comes first: only then is every tmux session with a pane in the worktree killed (`kill-session -t =name`, exact), the worktree removed, and the local branch deleted, which by then names nothing the merged PR's head ref does not keep. A worktree with uncommitted changes is reported and left with its sessions. Detached worktrees, and the checkout itself, are never touched.
5. **Reports what needs a person**, once per condition per head and again every three hours while it holds: a verdict that blocks (the review is on the PR, and the session that opened it may not carry the channel that would deliver it); a draft untouched for fifteen minutes (CI and the reviewer never run on a draft); a green PR with Proof boxes unticked; a ready PR with no validate run; a run cancelled with nothing after it; and a PR nothing has touched for forty-five minutes while no run is in progress, with the run's conclusion and its red jobs.

Thresholds are constants at the top of the script (`GRACE`, `SETTLE`, `IDLE`, `REPEAT`, `SWEEP`, `PUBLISH_RETRY`, `PUBLISH_KEEP`). Every line that stands while its condition does — a report, a refusal, a read that failed — is said once per `REPEAT`; a merge, a rerun, a publish and a sweep are said when they happen.

## Where the report goes

One message per pass that did or found anything, posted to **buddy-prime**'s mesh bridge over the fleet's authenticated route — `POST /mesh/buddy-prime/deliver` on the LAN Traefik, the same call buddybox's own bridge makes when it forwards — with `from` this host's verified mesh name, `buddy-janitor`, `sender` `topo-janitor`, and this host's peer token as the bearer. It arrives in buddy-prime as a turn from `buddy-janitor/topo-janitor`, and, like every relayed message, is mirrored in full to `#agent-mesh`. A quiet pass sends nothing. A report the far bridge does not take (no answer, a 403, a 503) is kept in the state file and sent at the front of the next one, up to 200 lines, the oldest dropped with a line saying how many; a 400 is the bridge refusing the message for good, and the lines are dropped with a note in the log. buddy-prime is the coordinator (`docs/process.md`): what it does with a line is its judgement, and nothing here reaches Sam directly.

It does not go through the local `~/.claude/sessions/` registrations: on buddybox the bridge registers its roster peers under thread ids, which macOS does not count as live processes, so the bridge's own sweep removes them within a minute and no local `buddy-prime` socket stands.

## What it holds

The launcher sources `~/.bashenv.local` for `GH_TOKEN`, Sam's classic PAT (`repo`, `workflow`): the merge, the rerun and every read are made as him, and the token is what lets `gh run rerun` touch Actions. `~/.mesh-bridge-env` holds `BRIDGE_PEER_TOKEN`, this host's own mesh identity, read by the janitor for the report and never logged. The publish runs `publish-topo.sh`, which pushes to samdu/experiments as the checkout's git credential and bounces the `ota` deployment with `~/.kube/config`, scoped to the experiments namespace, and signs with the Apple Development identity in buddy's login keychain, which is why the pass runs in the GUI session. Nothing of this reaches a log line or a report.

## State

`~/.local/state/topo-janitor/state.json`: which report keys fired and when, which heads have had their rerun, each publish attempt by commit with its outcome, and the undelivered lines. Written whole to a temporary file and renamed. Keys for heads no open PR carries are dropped at the end of a pass that read the PR list — never on one that could not, since an unread list is not an empty one — and publish records after a week, a sweep's once its worktree is gone. `state.json.lock` is held for the pass, and a pass that finds it held exits; a pass that stops on an error still delivers what it did before and saves.

## Running it

The LaunchAgent `zone.hexagon.topo-janitor` (dotfiles, installed by `setup.sh` on buddybox) runs `tools/topo-janitor` every fifteen minutes: it fetches origin and runs `scripts/janitor.py` as it is on origin/main, so the janitor is never the checkout's stale copy and never edits the checkout. By hand:

```sh
scripts/janitor.py --dry-run --verbose    # decide everything, run nothing, print the report
scripts/janitor.py                        # one pass
```

`scripts/tests/janitor-test.sh` holds the decisions over scripted readings and whole passes against a fake `gh`, `git`, `tmux` and `curl`, with buddy-prime's bridge played by a loopback server, in the PR check.

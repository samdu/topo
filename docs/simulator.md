# Running Topo in the simulator, signed in

The iOS Simulator is where a change is tried against a real Claude account before it goes to the reviewer: the app signs in, takes a turn, and the reply lands in the same CloudKit log the phone build reads. `scripts/simulator-run.sh` on buddybox does the whole of it.

## The one rule

**A debug build only ever talks to Haiku.** `ClaudeModel.pinned` in `Packages/TopoTurn/Sources/TopoTurn/MessagesAPI.swift` is `.haiku45` under `#if DEBUG` and nil otherwise, and `MessagesAPI.complete` puts the request's model through `ClaudeModel.effective` — so the pin is at the wire, not at the picker, and every caller obeys it: the chat's own turn, `answerPending`, and anything added later. The chat menu still offers Sonnet, Opus and Fable, and in a debug build all three go to Haiku; `MessagesAPITests.aDebugBuildAsksHaikuWhateverTheSettingSays` is what holds that.

Three things would get past it, and all three are visible: building Release (`-configuration Release`, or an archive — `scripts/archive-upload.sh` is a release build and is meant to be), editing `pinned`, or a turn taken by something that is not this app on this build — the hub, or a `claude` CLI somebody runs by hand.

## The token

Sam's long-lived Claude Code setup token (`claude setup-token`, inference only) lives in the 1Password Homelab vault as `long-lived-claude-auth-token`, field `oauth token`, and reaches the Macs as `CLAUDE_SETUP_TOKEN`. The script reads it from that variable, or from the vault with `op-item` when it is not set, and hands it to the app as `SIMCTL_CHILD_TOPO_CLAUDE_SETUP_TOKEN`.

An environment variable is the whole delivery: it lives in the launching shell and the launched process and nowhere else. It is not in the scheme (which is generated from `project.yml` and committed), not in a build setting, not in a file the app reads, and not in the `.app` — so no build, artifact or commit carries it, and nothing survives that a screenshot or an `ipa` could leak.

`DebugRun.signIn` writes it into the store as a finished sign-in, which is why the simulator comes up past the sign-in screen with no browser and no paste. A setup token has no refresh token, so none is stored; it is written with a 30-day life (`TOPO_CLAUDE_SETUP_TOKEN_DAYS`) so no run tries to exchange it. It then sits in **that simulator device's keychain** until the device is erased — `scripts/simulator-run.sh --erase` is how, and it is worth doing when a simulator is finished with.

## A run

From the cluster, through buddybox's GUI session, because `xcodebuild` needs the login keychain (see the wiki's `macs` page):

```bash
ssh buddybox 'sudo launchctl asuser $(id -u) sudo -u buddy bash -lc \
  "cd ~/github/topo && scripts/simulator-run.sh --send \"what did I forget this week\" --screenshot ~/Desktop/topo-sim.png"'
```

What it does, in order: builds the `Topo` scheme Debug for the named simulator (`DEVICE`, an iPhone 17 by default), boots it, installs the app, and launches it with the token in its environment. With `--send` the app takes exactly one turn through the ordinary harness — the primary lease, the append-only log, `MessagesAPI` — and prints each step prefixed `[topo-debug]`, ending in `done`. The script waits for that line, then asserts a `reply:` line came back and no `error:` line did; it exits non-zero if either fails. Without `--send` it just leaves a signed-in simulator on screen to drive by hand.

The turn is a real one: it spends Sam's subscription (a Haiku turn, so barely) and it appends to his real Topo transcript in the development container, which is the point — it is the path the phone takes.

## What needs Sam

- **An iCloud account signed into the simulator device**, once per device: Settings › Sign in to your iPhone, Sam's Apple ID and its two-factor code. Without it CloudKit answers `noAccount`, the log cannot be written, and a `--send` run fails at "Reaching iCloud…" rather than at the model. Nothing else in the run needs a person: the build is signed automatically from the certificate already in `buddy`'s login keychain, and there is no Xcode dialog on this path.
- Nothing else. In particular no keychain unlock: `launchctl asuser` puts the build in the GUI session, where the certificate's keychain is already open.

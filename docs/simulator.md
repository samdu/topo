# Running Topo in the simulator, signed in

The iOS Simulator is where a change is tried against a real Claude account before it goes to the reviewer: the app signs in, takes a turn, and the reply lands in a real CloudKit log — Buddy's own, not Sam's. `scripts/simulator-run.sh` on buddybox does the whole of it.

## The one rule

**A debug build only ever talks to Haiku.** `ClaudeModel.pinned` in `Packages/TopoTurn/Sources/TopoTurn/MessagesAPI.swift` is `.haiku45` under `#if DEBUG` and nil otherwise, and `MessagesAPI.complete` puts the request's model through `ClaudeModel.effective` — so the pin is at the wire, not at the picker, and every caller obeys it: the chat's own turn, `answerPending`, and anything added later. The chat menu still offers Sonnet, Opus and Fable, and in a debug build all three go to Haiku; `MessagesAPITests.aDebugBuildAsksHaikuWhateverTheSettingSays` is what holds that.

Three things would get past it, and all three are visible: building Release (`-configuration Release`, or an archive — `scripts/archive-upload.sh` is a release build and is meant to be), editing `pinned`, or a turn taken by something that is not this app on this build — the hub, or a `claude` CLI somebody runs by hand.

## The token

Sam's long-lived Claude Code setup token (`claude setup-token`, inference only) lives in the 1Password Homelab vault as `long-lived-claude-auth-token`, field `oauth token`, and reaches the Macs as `CLAUDE_SETUP_TOKEN`. The script reads it from that variable, or from the vault with `op-item` when it is not set, and hands it to the app as `SIMCTL_CHILD_TOPO_CLAUDE_SETUP_TOKEN`.

An environment variable is the whole delivery: it lives in the launching shell and the launched process and nowhere else. It is not in the scheme (which is generated from `project.yml` and committed), not in a build setting, not in a file the app reads, and not in the `.app` — so no build, artifact or commit carries it, and nothing survives that a screenshot or an `ipa` could leak.

`DebugRun.signIn` writes it into the store as a finished sign-in, which is why the simulator comes up past the sign-in screen with no browser and no paste. A setup token has no refresh token, so none is stored; it is written with a 30-day life (`TOPO_CLAUDE_SETUP_TOKEN_DAYS`) so no run tries to exchange it. It then sits in **that simulator device's keychain**, so the device stays signed in across runs, a reinstalled app included, until the device is erased.

## Whose account the simulator is on

The simulator device is signed into **`buddy.durose@icloud.com`**, Buddy's own Apple ID. The container is the one every bundle uses, `iCloud.zone.hexagon.topo`, but a private database belongs to whichever account is signed in, so the log a run writes is that account's: a turn sent from a simulator never reaches Sam's transcript, and nothing of his is readable from one. Send whatever a test needs.

Both sign-ins are per device and both persist: the iCloud account and the Claude setup token in the keychain stay until `scripts/simulator-run.sh --erase`, which returns that device to a factory one and takes both with it. So the sign-in is paid once per simulator device, and erasing one is what to do when it is finished with — after which the next run needs the iCloud sign-in by hand again.

## A run

From the cluster, through buddybox's GUI session, because `xcodebuild` needs the login keychain (see the wiki's `macs` page):

```bash
ssh buddybox 'sudo launchctl asuser $(id -u) sudo -u buddy bash -lc \
  "cd ~/github/topo && scripts/simulator-run.sh --send \"what did I forget this week\" --screenshot ~/Desktop/topo-sim.png"'
```

What it does, in order: builds the `Topo` scheme Debug for the named simulator (`DEVICE`, an iPhone 17 by default), boots it, installs the app, and launches it with the token in its environment. With `--send` the app takes exactly one turn through the ordinary harness — the primary lease, the append-only log, `MessagesAPI` — and prints each step prefixed `[topo-debug]`, ending in `done`. The script waits for that line, then asserts a `reply:` line came back and no `error:` line did; it exits non-zero if either fails. Without `--send` it just leaves a signed-in simulator on screen to drive by hand.

The turn is a real one: it spends Sam's subscription (a Haiku turn, so barely) and it appends to the simulator account's Topo transcript in the development container, which is the point — it is the path the phone takes.

## Pressing the microphone

The microphone press is covered by an XCUITest, `TopoUITests` (`Tests/ClientUI/MicrophonePressTests.swift`), which is what `simctl` alone cannot reach: it drives the running app, taps through the permission prompts on SpringBoard, and taps, holds and releases the button on the chat screen, holding after each that the app is still running and the button is back at rest, and after the hold that its session either ran the microphone or was refused for the one reason a host may have, no audio input (`VoiceInput.sessions` and `VoiceInput.refusal`, read from the button's debug-only accessibility value, `"<n> heard[; <refusal>]"`). A press refused for any other reason — a permission, the recogniser unavailable, the engine failing to start — fails the test, so a microphone silently refused cannot pass as one that ran. The tap is survived rather than asserted on: a press released before the microphone is running starts nothing, by design, and a synthesised tap is shorter than the permission hops and the engine start. A crash on the press — an instant one included — is an app that is no longer `runningForeground`, whichever layer it came from: this catches a trap or an Objective-C exception that `VoiceInput.begin`'s `do`/`catch` never sees, not only a Swift error. The test is in the `Topo` scheme's test action, so the PR check runs it beside the unit suite; `scripts/simulator-run.sh --press-mic` runs it by hand on buddybox.

It launches the app signed in with a placeholder token (a press in the simulator hears nothing, so nothing is sent and the token never reaches the API) and past the first-run question, straight to the chat screen.

Two launches, one per branch of `VoiceInput.begin`:

- **The fallback branch, `SFSpeechRecognizer`'s**, which is the one a real simulator takes anyway.
- **The on-device branch**, over `TOPO_DEBUG_EAR=stub` (`DebugRun.ear`): an `Ear` resident without a model, so the press takes `begin`'s local branch over an engine that hears nothing. On a host with an audio input that is the input tap, `SampleSink`, the caption loop and the decode at the release; on one without, it is everything up to the input guard (below).

### What the press cannot reach here

**A host with no audio input has no microphone to press.** The simulator routes the Mac's default input, and buddybox is a Mac mini with none, so there `AVAudioEngine`'s input node reports a dead format and `begin` refuses the press at its own guard (`VoiceInput.noInput`) before any tap is installed: on buddybox both launches exercise the permission prompts, the recogniser choice, the audio session's record claim, the guard and the teardown, and neither reaches the tap, the sink or the caption loop. Those run only on a host with an input — a Mac with a microphone, or whatever the CI runner has — and the test tells the two apart rather than passing blind.

**The simulator has no Metal, so neither Parakeet nor Pocket is ever resident on it.** The on-device *code path* runs where there is an input, but the CoreML decode itself, and any trap inside FluidAudio's `transcribe` or `VocabularyBoostingSession`, is out of reach in a simulator and only a real device exercises it. Pocket TTS is the same — `Voice.prepare` fails with "no Metal in the simulator", so the speaker always takes `AVSpeechSynthesizer`. The stub stands in for the model so the app's own on-device branch is tested; the model's own behaviour is not.

## What a shell cannot reach

`simctl` has no tap. It boots a device, installs and launches an app, and captures the screen, and there is no command in it that touches what is on that screen; System Events cannot see the Simulator's window either, so an AppleScript UI script finds nothing to click. Anything behind a gesture is out of reach from a *shell* — which is why the microphone press is an XCUITest (above) rather than a `simctl` step; screenshots are the same, so `--screenshot` captures whatever the app came up on and nothing further in.

That is the shape of the whole shell path: what a run can exercise from a shell is what the launch environment can drive — the sign-in `DebugRun` writes, the one turn `TOPO_DEBUG_SEND` takes — and the gestures are the XCUITest's or a person's at the Simulator on buddybox.

## What needs a person

- **The iCloud sign-in on the simulator device**, once per device: Settings › Sign in to your iPhone, `buddy.durose@icloud.com` and its two-factor code. It is a gesture, so it is done at the Simulator rather than from a shell. Without an account CloudKit answers `noAccount`, the log cannot be written, and a `--send` run fails at "Reaching iCloud…" rather than at the model.
- Nothing else. The build signs itself from the certificate already in `buddy`'s login keychain, there is no Xcode dialog on this path, and no keychain unlock: `launchctl asuser` puts the build in the GUI session, where the certificate's keychain is already open.

# Roadmap

What is built, what comes next and in what order, what is parked, and the threads open right now. Sam's decisions and the reasoning behind them live in the wiki page [buddy-for-helen](https://github.com/samdu/memory/blob/main/wiki/buddy-for-helen.md) in `samdu/memory`; this page is the build order that follows from them. The design is `docs/design.md`, the process `docs/process.md`.

## Built and shipped

- The CloudKit log, the primary lease, the device directory and the role record (`Packages/TopoCore`), with the in-memory database the suites run against. The lease runs one operation at a time with every request bounded at 4 s (#314), and a reply is saved when the lease's heartbeats ran late and nobody else claimed (#302).
- A sent message does not wait on CloudKit: the guest hears the words before the lease is taken and the turn saved, so with iCloud away and Anthropic reachable a phone that has read the log keeps answering (#323).
- Sign in with Claude (`Packages/TopoAuth`): the ordinary tokens and the guest's long-lived token, both in the device keychain.
- The phone harness (`Packages/TopoTurn`): the outbox and the row, the nonce contract, the answering loop, the silent push for a limb's turn.
- The guest: iSH's arm64 kernel in the app's process, Alpine with bash, Claude Code pinned at 2.1.285 and mounted, the API proxy on loopback, the resident process with its lifecycle across foreground and background (`Packages/TopoUserland`, `Packages/TopoProxy`). The emulator decodes the NEON that Claude Code's binary uses (#250, #320), keeps the phone's time zone (#251), survives a guest `umount` of a tmpfs (#318) and chains a translated block's exit only while its slot still holds it (#316).
- The transcript bridge: the guest is the only brain, the ledger lines its conversation up with the log across crashes, and an unfinished turn is asked again by hand.
- One brain (P5b): `TurnRunner` asks a `Brain` and the app has one, the guest; the package suite drives the runner over a scripted brain and the app's suites drive the harness over the guest.
- Voice: push to talk on Parakeet, replies read on Pocket TTS, both downloaded by the app and held behind the lock. The voice starts at a reply's first sentence, as it is written (#297).
- The memory as an Obsidian vault: local or in iCloud Drive, mirrored both ways under file coordination, moved between homes with one commit point, and mounted into the guest at `/home/topo/memory` with every open coordinated, so the mind reads and writes its own notes.
- The look as a document (`look.json`), the glass composer that goes short under the keyboard, the badge, and the transcript drawn by phone, watch and television.
- Topo on the glass: the pixel engine, poses from the guest's events, a calm idle with yoga, facing by side, roaming the chat without juddering under a turn. He is thinking from a turn's start to its end, and idle only when no turn is open (#305).
- The mute and the model slider on the glass, Topo sitting over the model chosen; the models sent as aliases and named by the look (#319); the settings sheet with where Topo sits first, Tuning's sliders in debug, diagnostics, About with the GPL text and the source commit.
- Topo's placement: roam, glass or pinned by a long-press drag, kept in this device's override (#165); when nothing clears the words he stands where the least of his box covers them (#172).
- A reply on the screen: Topo's turns drawn as markdown from Foundation's parser, styled by `Look.Markdown` — fenced and inline code, emphasis, headings, lists, quotes and rules (#173), tables that scroll sideways, web links that open on a tap, the words written before a tool call, and images read through the guest (#324). A cued code block pulses and stays scrolled to (#212, #239).
- The phone's own tools (P7): a loopback tool service and the `topo` CLI in the guest, found by a skill, with `topo look`, reminders, calendar, notify, contacts and location (#189, #214).
- P7c's HomeKit and Maps: `topo home` lists, gets and sets accessories and runs scenes, behind the HomeKit entitlement (#226); `topo maps` answers places, a route and a travel time from Apple Maps through MapKit, without opening Maps (#287).
- P7d, the guest on the network: it reaches the internet directly through the app's sockets and does its own TLS, and it resolves names through the phone's own resolver while the forwarder is up: its `/etc/resolv.conf` names `127.0.0.53`, which the emulator carries to a loopback DNS forwarder in the app, so Private Relay, a VPN's split DNS and a DNS profile follow the phone; what the file holds when the forwarder is down is `docs/guest.md`'s (#225, #242, #269). There is no egress proxy. `apk` works from the guest as it is, and git and `gh` are one `apk add` away, since the rootfs ships only Alpine's minirootfs and bash.
- Connections: GitHub by device flow against Topo's OAuth App and a 1Password vault by a service-account token, connected from a Connections screen. The app holds each token in the Keychain, and the guest gets one on demand for a single `git`, `gh` or `op` process through `topo github` and `topo secret`, never keeping it (#236, #238, #267).
- The phone's widgets and controls: `topo widget` writes home-screen and lock-screen widgets the mind designs, with controls that cue a turn or run one `topo` call, drawn by a WidgetKit extension from the app group, over a default of the newest reply (#262). The phone's slots reach the watch face as `Surface` records, where a tap cues a turn or opens Topo (#270). `topo control` writes a Topo Button and a Topo Toggle for Control Center, the lock screen and the Action button, with a `request` action that reaches a URL (#271). `docs/widgets.md`.
- Speed: a whole-type read asks CloudKit only for what changed, the guest and Claude Code start as the chat appears, and a reply is streamed to the row (#297), measured by marks at every step of a launch and a turn and a hands-free timed run (#296, `docs/perf.md`).
- Womble for iOS 12 devices, viewer only.
- The hub app skeleton (`TopoHub`), holding the lease and showing the pairing code.
- CI: the PR check's parallel jobs with the audio lane, suites chosen by the paths a PR changes, the Codex reviewer and its gate, the simulator runbook, OTA builds from `samdu/experiments`, and the janitor (`docs/janitor.md`) that merges what automerge missed, reruns an infrastructure red, republishes the install page, sweeps merged worktrees and triages new issues into `next`, `parked` and `flake` (#303).

## Next, in order

1. **P7c: the phone's tools, round two.** What is left, in this order: Photos and the document picker (search albums, export, save; pick a file into the vault), the share sheet inbound (text, links, images, files arriving as a turn), Shortcuts intents (Ask, quick task, follow-up), and a screen share (a ReplayKit broadcast extension, the same route Discord takes, so Topo watches the whole phone while you are in another app; the extension keeps a still every second or two, or on change, and the mind reads stills, never video). Each a `topo` verb behind the same loopback service as P7, permission asked on first call, nothing destructive. OpenMinis' offloads are the map.
2. **The tools the mind already has, made right.** `topo reminders` with no arguments prints every open reminder, 79 KB on Sam's phone (#245); the vault's `.topo` is forbidden rather than hidden, so every `ls` of the memory exits 1 (#246); `topo location` names the nearest address rather than the flat's (#247); `topo secret` cannot say what an item holds (#249); `topo maps` answers no Apple Maps link the person can tap (#289); and the guest cannot read the app's own log lines (`topo log`, #281).
3. **The guest holds up.** `Guest.run` answers status 0 with empty output when the guest command hangs (#295); a store to a page of translated code can be followed by a compile of the old bytes (#315); `mount_find`'s thread-local cache is read outside `mounts_lock`, so a concurrent umount can hand back a freed mount (#317). Each is a patch under `patches/ish/` or a bound in `Guest`.
4. **Widgets and controls, round two.** The watch's `run` action runs in place rather than opening the app (#327); a control's slot picker shows each slot's title (#280); a widget's tint keeps its alpha, so a clear background is reachable (#282); a widget's action carries the control's `request` (#283) and can run a Shortcut or open a URL (#284).
5. **A reply on the screen, round two.** A control on a code block or a table that opens it full screen, and a copy button on code (#179, #217); a list item whose first block is a quote keeps its bullet (#183); an image re-read after a vault change does not wait behind the read in flight (#325).
6. **The first run and a full context.** The chat draws empty until the first CloudKit read returns, and no first-run progress plan is written (#161); the first-run screen shows after sign-in when the log already has turns (#128); the badge goes yellow and nothing in the app compacts the mind's context (#255).
7. **The keyboard (#329).** Typing a turn on the glass, redesigned by Sam; the composer was built round push to talk, and the typed path has not had its turn. The design is on the issue's thread, not yet a plan.
8. **P8: TestFlight with the guest.** Bundle size, export compliance re-judged now that a rootfs with OpenSSL ships, the App Review risk written down (`docs/testflight.md`), and the `Surface` schema promoted to production first (#285). Last, and not before Sam would show Topo to someone else: each step before it changes what review sees, and living on Topo day to day is what finds the steps.

Beside the order, on the pipeline rather than the product: the simulator's iCloud sign-in lapses and is re-authenticated by hand (#83); `pm-guard` refuses code edits in an engineer's worktree when the session's project dir is that worktree (#310); `ci-audio-lane.sh start` leaves the last lane's `supervisor.started` in place until the new supervisor is up (#311); two lease follow-ups from #314's review (#321).

## Parked, and why

- **The hub as a running mind.** `TopoHub` holds the lease and shows the pairing code but runs no turns; the phone is the primary until the guest path is complete, since it has to stand-alone if it's a user's only device.
- **Full Messages access on the hub.** iOS gives a third-party app no way to read or send iMessages, so this is the Mac's alone: the hub reads the Messages database and sends through Messages.app, the way the buddybox relay does. Waits on the hub running turns.
- **Sockets and the tunnel** (`Packages/TopoLink` beyond the LAN probe). CloudKit is truth and works with no socket; speed comes after the mind does.
- **The house board** (`docs/board.md`). Designed, with `TopoBoard` in place; no screen draws it until one person's mind is worth sharing a wall with.
- **A fresh lease renewed with the person's save (#306).** Two CloudKit round trips out of every warm turn, by saving the turn in the renewal's batch. Its review holds it on a successor instance's claim being taken for this instance's own, and it rewrites the top of `TurnRunner.run`, which #323 has since changed under it.
- **What the lease's redesign (#314) left.** The heartbeat runs on after sign-out and after a demotion, since `Harness.forget()` drops the lease without abandoning it (#148); a phone that staked primary at first launch and then lost the lease to the hub is never demoted, since a first-launch stake writes no role record (#273). Both wait on a rule for them in `PrimaryLease`.
- **swift-markdown as the parser (#179).** The parser #179 names. Everything a reply draws today, tables and links included, comes from Foundation's parser, so nothing on the screen needs the dependency.
- **The mascot as a movement system (#177)** and the ink he splashes on a correction (#181). An extensible, agent-programmable engine with a jet, studied from game characters and NPCs; the survey comes first and is not begun.
- **A hidden terminal onto the guest's Claude Code (#133).** An escape hatch for a prompt the app does not draw; waits until the headless path has settled.
- **On-device storage (#309, #117, #87).** Bounding the ANE compile cache, clearing tmp on launch and the model housekeeping residue start from a fresh measurement on the phone; the voice pack's ten-minute download is the same subject.
- **The local gate's aftermath (#312, #308).** Confirming the hosted macOS jobs are gone and rechecking the flakes seen only on hosted runners wait on the Mac suites moving to buddybox.
- Small ones, each a nice-to-have or hardening residue with nothing failing today: a claim change with no hold standing is still attempted from the background (#90); an empty parents list is left off the wire (#96); the same-folder guard on a move compares URLs, not directory identity (#103); a query of mostly digits is read as a number (#240); an existing fakefs never gets a package added to the manifest after import (#254); the resident keeps its own clock across a zone change until the next launch (#256).

## Open threads

- **Topo as a mesh peer (#277).** Sessions hand Topo a device check and get the output back without Sam relaying; today a mailbox on `samdu/topo-link#1` carries it.
- **A "topo" menu** with menu-items populated by the agent themselves. Quick access to frequent settings, long-press the octopus (conflicts with dragging topo, TBD)
- need to implement a (+) button on the glass for inserting attachments
- need an effort selector beside the model slider on the glass
- first-run progress screen with progress bars for environment setup, speech setup, and transcription setup — need to decide how to show this progress when launching a newly-updated app that already has a log, since it will jump straight to the transcript while things download in the background (#161)

### Deferred proof gaps

Findings a review left non-blocking, each kept as an issue against the PR it came from.

- **#132**: `StoredTokenProvider`'s overlap test ignores its hold's timeout, and nothing tests another writer replacing tokens mid-refresh.
- **#147**: the review-prompt tests bind `HEAD_SHA` and `BASE_SHA` directly and leave the truncation defaults untested.
- **#149**: five corner cases of the transcript bridge from #143's last read.
- **#153**: no test that a package file wins over a rootfs path it shares in the combined import.
- **#160**: the mascot and the glass, from #151 and #157.
- **#211**: three voice cases of speakable text, from #207.
- **#213**: three findings on the memory mount, from #200.
- **#221**: the phone's tools, from #214 and #226.
- **#286**: the watch's widgets, from #270.
- **#292**: `StoneRenderTests`' floor-of-the-cut needs a second stone asset, and `ComposerRenderTests` should assert `openCast` reaches the floor alone.
- Guest transcripts under the guest's home are not wiped at sign-out; no issue yet.

### Flakes on CI

#88, #97, #124, #227, #231, #257, #264, #293, #313, #322: each fails now and then and passes on a rerun, noted rather than fixed; #231 is also labelled `next`. #308 holds the ones seen only on GitHub's hosted macOS runners.

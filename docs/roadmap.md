# Roadmap

What is built, what comes next and in what order, what is parked, and the threads open right now. Sam's decisions and the reasoning behind them live in the wiki page [buddy-for-helen](https://github.com/samdu/memory/blob/main/wiki/buddy-for-helen.md) in `samdu/memory`; this page is the build order that follows from them. The design is `docs/design.md`, the process `docs/process.md`.

## Built and shipped

- The CloudKit log, the primary lease, the device directory and the role record (`Packages/TopoCore`), with the in-memory database the suites run against.
- Sign in with Claude (`Packages/TopoAuth`): the ordinary tokens and the guest's long-lived token, both in the device keychain.
- The phone harness (`Packages/TopoTurn`): the outbox and the row, the nonce contract, the answering loop, the silent push for a limb's turn.
- The guest: iSH's arm64 kernel in the app's process, Alpine with bash, Claude Code pinned and mounted, the API proxy on loopback, the resident process with its lifecycle across foreground and background (`Packages/TopoUserland`, `Packages/TopoProxy`).
- The transcript bridge: the guest is the only brain, the ledger lines its conversation up with the log across crashes, and an unfinished turn is asked again by hand.
- One brain (P5b): `TurnRunner` asks a `Brain` and the app has one, the guest; the package suite drives the runner over a scripted brain and the app's suites drive the harness over the guest.
- Voice: push to talk on Parakeet, replies read on Pocket TTS, both downloaded by the app and held behind the lock.
- The memory as an Obsidian vault: local or in iCloud Drive, mirrored both ways under file coordination, moved between homes with one commit point, and mounted into the guest at `/home/topo/memory` with every open coordinated, so the mind reads and writes its own notes.
- The look as a document (`look.json`), the glass composer that goes short under the keyboard, the badge, and the transcript drawn by phone, watch and television, Topo's turns as markdown.
- Topo on the glass: the pixel engine, poses from the guest's events, a calm idle with yoga, facing by side, roaming the chat without juddering under a turn.
- The model picker, Tuning (placement and pin in every build, sliders in debug), diagnostics, About with the GPL text and the source commit.
- Topo's placement: roam, glass or pinned by a long-press drag, kept in Tuning (#165); when nothing clears the words he stands where the least of his box covers them (#172, in its fix round).
- Markdown in Topo's replies: fenced and inline code, emphasis, headings, lists, quotes and rules from Foundation's parser, styled by `Look.Markdown` (#173).
- Womble for iOS 12 devices, viewer only.
- The hub app skeleton (`TopoHub`), holding the lease and showing the pairing code.
- CI: the three-job PR check with the audio lane, the Codex reviewer and its gate, the simulator runbook, OTA builds from `samdu/experiments`.

## Next, in order

1. **P7: the phone's own tools.** A loopback tool service and a small `topo` CLI in the guest (calendar, reminders, contacts, location, notify), found by a skill rather than paid for per turn. After P6, since notes are the tool everything else writes into.
2. **P8: TestFlight with the guest.** Bundle size, export compliance re-judged now that a rootfs with OpenSSL ships, the App Review risk written down (`docs/testflight.md`). Last because each step before it changes what review sees.

Not sequenced, on the issue list: #172's fix round and its re-review; #129, the proxy's debug pin skipping a non-canonical `/v1/messages` path; #177, Topo's movement under fast scrolling (a survey of game steering first); #178, nested blockquotes; #179, markdown round two — swift-markdown as the parser, tables that scroll sideways, tap-to-full-screen on code and tables, tappable links.

## Parked, and why

- **The hub as a running mind.** `TopoHub` holds the lease and shows the pairing code but runs no turns; the phone is the primary until the guest path is complete, since it has to stand-alone if it's a user's only device.
- **Sockets and the tunnel** (`Packages/TopoLink` beyond the LAN probe). CloudKit is truth and works with no socket; speed comes after the mind does.
- **The house board** (`docs/board.md`). Designed, with `TopoBoard` in place; no screen draws it until one person's mind is worth sharing a wall with.

## Open threads
- **A "topo" menu** with menu-items populated by the agent themselves. Quick access to frequent settings, long-press the octopus (conflicts with dragging topo, TBD)
- need to implement a (+) button on the glass for inserting attachments
- need a model + effort selector on the glass — opens to a panel with a model size slider, topo remains visible with this panel open so his head size can react in real time to model changes
- first-run progress screen with progress bars for environment setup, speech setup, and transcription setup — need to decide how to show this progress when launching a newly-updated app that already has a log, since it will jump straight to the transcript while things download in the background

### Deferred proof gaps

- **#161**: the chat draws empty until the first CloudKit read returns; a first-run progress plan has not been written.
- **#128**: the first-run screen shows after sign-in when the log already has turns.
- **#148**: the lease's heartbeat runs on after sign-out.
- **#135**: Claude Code in the guest sometimes exits 0 at start with no output, about one start in eight; the resident restarts, so it costs a resume.
- **#87**: the voice pack takes about ten minutes to download on the phone.
- Guest transcripts under the guest's home are not wiped at sign-out; no issue yet.

### Flakes on CI

#91, #122, #124, #126, #127, #141, #146, #159: each is a timing bound on a cold runner, noted rather than fixed. `topo_ui`, at about 19 minutes, is the long pole; `topo_unit` takes about 17.

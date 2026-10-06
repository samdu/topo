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
- Topo's placement: roam, glass or pinned by a long-press drag, kept in Tuning (#165); when nothing clears the words he stands where the least of his box covers them (#172).
- Markdown in Topo's replies: fenced and inline code, emphasis, headings, lists, quotes and rules from Foundation's parser, styled by `Look.Markdown` (#173).
- The phone's own tools (P7): a loopback tool service and the `topo` CLI in the guest, found by a skill, with `topo look`, reminders, calendar, notify, contacts and location (#189, #214).
- P7c's HomeKit: `topo home` lists, gets and sets accessories and runs scenes, behind the HomeKit entitlement (#226).
- P7d, the guest on the network: it reaches the internet directly through the app's sockets and does its own TLS, and its `/etc/resolv.conf` holds the phone's own name servers, VPN included, written at boot and again on every network change (#225, #242). There is no egress proxy; `apk` works from the guest as it is, and git and `gh` are one `apk add` away, since the rootfs ships only Alpine's minirootfs and bash.
- The phone's widgets: `topo widget` writes home-screen and lock-screen widgets the mind designs, with controls that cue a turn or run one `topo` call, drawn by a WidgetKit extension from the app group, over a default of the newest reply (`docs/widgets.md`). The watch's widgets and Control Center controls are the plan's PRs B and C.
- Womble for iOS 12 devices, viewer only.
- The hub app skeleton (`TopoHub`), holding the lease and showing the pairing code.
- CI: the three-suite PR check with the audio lane, run on buddybox before each push, the Codex reviewer and its gate, the simulator runbook, OTA builds from `samdu/experiments`, and the janitor (`docs/janitor.md`) that merges what automerge missed, reruns an infrastructure red, republishes the install page and sweeps merged worktrees.

## Next, in order

1. **P7c: the phone's tools, round two.** HomeKit is built; the rest, in this order: Maps (place search, routes, ETAs), Photos and the document picker (search albums, export, save; pick a file into the vault), the share sheet inbound (text, links, images, files arriving as a turn), Shortcuts intents (Ask, quick task, follow-up), and a screen share (a ReplayKit broadcast extension, the same route Discord takes, so Topo watches the whole phone while you are in another app; the extension keeps a still every second or two, or on change, and the mind reads stills, never video). Each a `topo` verb behind the same loopback service as P7, permission asked on first call, nothing destructive. OpenMinis' offloads are the map.
2. **P7d: the guest reaches the network.** The guest has no egress proxy by design: it reaches the internet directly through the app's sockets and does its own TLS, so `apk` works from inside it, and git and `gh` once the guest has installed them (the rootfs ships only Alpine's minirootfs and bash). `GuestResolver` writes `/etc/resolv.conf` from the phone's DNS servers at boot and rewrites it on every network change (#225, #242). What is left is #243, a loopback DNS forwarder in the app, so a VPN's split DNS and the phone's encrypted DNS reach the guest too.
3. **Connections (#235).** GitHub and a 1Password vault, connected from a Connections screen: GitHub by device flow against Topo's OAuth App, 1Password by a service-account token scoped to one vault. The host holds each token in the Keychain, and the guest gets one on demand for a single `git`, `gh` or `op` process, never keeping it. #236 (the store, the screen and GitHub) and #238 (1Password, `topo secret`), in review. Their titles call this P8; the numbering here wins.
4. **P8: TestFlight with the guest.** Bundle size, export compliance re-judged now that a rootfs with OpenSSL ships, the App Review risk written down (`docs/testflight.md`). Last because each step before it changes what review sees.

Not sequenced, on the issue list: #129, the proxy's debug pin skipping a non-canonical `/v1/messages` path; #177, Topo's mascot as an extensible, agent-programmable movement system with a jet, studied from game characters and NPCs (survey first); #179, markdown round two — swift-markdown as the parser, tables that scroll sideways, tap-to-full-screen on code and tables, tappable links; #232, a cued code block at the foot of a row not yet made left off the screen, its fix in #239; #244, the guest's clock on UTC with no `TZ` or zoneinfo, so the mind reads the wrong time of day; #252, NEON instructions in Claude Code's binary the emulator still does not decode beyond SQABS and SQNEG, which #250 adds for #248's `grep -n`.

## Parked, and why

- **The hub as a running mind.** `TopoHub` holds the lease and shows the pairing code but runs no turns; the phone is the primary until the guest path is complete, since it has to stand-alone if it's a user's only device.
- **Full Messages access on the hub.** iOS gives a third-party app no way to read or send iMessages, so this is the Mac's alone: the hub reads the Messages database and sends through Messages.app, the way the buddybox relay does. Waits on the hub running turns.
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

#91, #122, #124, #126, #127, #141, #146, #159, #218: each is a timing bound on a cold runner, noted rather than fixed. #228's render reads are fixed in the tests (#230), its tall-row case being #232; #233's contact name is fixed in #241, in review. `topo_ui`, at about 19 minutes, is the long pole; `topo_unit` takes about 17.

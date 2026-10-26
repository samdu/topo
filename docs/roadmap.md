# Topo roadmap

How the pieces fit together is in `README.md`, `docs/design.md` and the area docs it links; this file is what has been built, what is in hand, what comes next, and what is parked or was tried and left. Sam's decisions and the reasoning behind them are the wiki page [buddy-for-helen](https://github.com/samdu/memory/blob/main/wiki/buddy-for-helen.md) in `samdu/memory`; the process is `docs/process.md`. Defects are [this repo's issues](https://github.com/samdu/topo/issues); tests that fail now and then and pass on a rerun carry the [`flake`](https://github.com/samdu/topo/issues?q=is%3Aopen+label%3Aflake) label.

## Today

Topo is the phone app. Signed in with Claude, the iPhone is the primary: the real Claude Code, pinned at 2.1.285, runs resident in an Alpine userland inside the app (iSH's arm64 emulator) with permissions bypassed, because the guest is the sandbox and what it reaches is the holes the app makes: the memory's folder mounted at `/home/topo/memory`, a loopback proxy that holds the login, a loopback tool service behind the `topo` command, a DNS forwarder onto the phone's resolver, and the internet directly. Every turn is written to the CloudKit log, which the watch, the TV, other iPhones and iPads as viewers, and Womble on old iPads read.

You talk to it by holding the jewel: Parakeet hears on the phone and Pocket TTS reads the reply aloud as it streams, behind the lock. The memory is an Obsidian vault, local or in iCloud Drive, that the mind reads and writes. Through `topo` the mind reaches reminders, the calendar, notifications, contacts, location, HomeKit, Apple Maps, Photos, the file picker, a shared screen, GitHub and 1Password, and writes the phone's widgets, the watch face's slots and Control Center controls. Things reach it from the share sheet and Shortcuts. A turn sent in front keeps running behind another app.

The Mac hub (`TopoHub`) holds the lease, shows the pairing code and serves the house's LAN surfaces; it runs no turns. Nothing is on TestFlight: Sam's gate is that it goes when he would show Topo to someone else.

## Done

Struck through: shipped, then removed, with the reason.

**The log and the roles**

- The CloudKit log, the primary lease, the device directory and the role record, against an in-memory database with CloudKit's semantics (#1, #21, #24); a whole-type read asks only for what changed (#297)
- The role at first launch from the lease record, a viewer making itself primary, a takeover that refuses a live holder (#27, #34, #36); a login found at first launch never makes a second primary beside another device's lease (#360)
- The lease runs one operation at a time with every request bounded at 4 s (#314); a fresh lease is renewed with the person's save (#306); a reply is saved when heartbeats ran late and nobody claimed (#302)
- A sent message does not wait on CloudKit: the guest hears the words before the save (#323)
- A limb's turn wakes the primary by a silent push (#44)

**The guest**

- iSH vendored and built, Claude Code fetched at its pin and mounted, bash, the API proxy on a token of its own (#116, #119, #120, #150)
- Claude Code resident, permissions bypassed, with its lifecycle across foreground and background (#134, #138, #139); the proxy's and the tool service's listeners started again after iOS takes them (#448)
- The guest is the only brain, behind one `Brain` seam, with the transcript bridge and its ledger (#143, #186)
- The emulator: NEON for Claude Code's binary (#250, #320), the phone's time zone (#251), a tmpfs `umount` (#318), block chaining (#316), a store to translated code (#428), `mount_find` under its lock (#427); `Guest.run` bounded (#422)
- The guest on the network: its own resolver, the phone's name servers, then the DNS forwarder at `127.0.0.53` (#225, #242, #269)
- A turn behind another app under a continued-processing task, with the ~29 s grace as the floor (#440); the bridge says why a reply failed (#449)
- A full context: compact now, a threshold the person and the mind set (#388)

**Voice**

- Push to talk with Parakeet on the device and the person's own vocabulary (#48, #51, #57, #85); replies in Pocket TTS behind the lock (#55, #86, #89); recovery from a media services reset (#78)
- Speakable text and code blocks cued by number (#207, #212); the voice from a reply's first sentence as it streams (#297)
- FluidAudio pinned at 0.17.7, which keeps a sentence whole up to Pocket's 512-position cache (#397); `marius` as the voice, at his own pace (#400); the voice's temperature as a setting, 0.5 unless changed (#411); Topo's own voice pack (#415); noise suppression through Apple's voice processing (#385)
- ~~Kokoro's `bm_buddy` blend as the voice~~ (#49; replaced in #55 by Pocket TTS on the device)
- ~~Apple speech as the ear's and the voice's fallback~~ (#48, #49; removed in #85, #86: one ear and one voice, both FluidAudio on the device, no fallback)
- ~~Pocket's `eponine` as the voice~~ (#55; `marius` in #400)

**The chat and Topo**

- The look as a document the mind writes (#106); the glass composer and the cabochon (#104, #110, #113); the composer as one row of glass (#333)
- The mute and the model's brain in the bar, the model's slider under it, models sent as aliases (#319, #347, #366)
- Topo on the glass: idle and yoga, roaming, facing, placement by long-press drag, never undrawn for want of a clear spot (#140, #155, #157, #162, #165, #172); thinking from a turn's start to its end (#305)
- A reply drawn as markdown from Foundation's parser: code, quotes, lists, tables, links, the words before a tool call, images (#173, #182, #324)
- The first run: nothing decided before the log is read, the question held on Topo's sign (#386, #443); Sign in with Claude ends on the chat (#405); the GitHub device code on a sign (#444)
- Perf marks and a hands-free timed run (#296)

**The memory**

- The vault, mirrored both ways, in the app's container or a folder in iCloud Drive, moved between homes (#14, #93, #100); mounted into the guest with every open coordinated, `.topo` hidden (#200, #342)

**The phone's tools**

- The tool service and `topo look` (#189); reminders, calendar, notify, contacts, location (#214, #341, #348); `topo home` (#226); `topo maps` with a tappable Apple Maps link (#287, #348); `topo log` (#348)
- Photos and the file picker (#362); the screen share (#377)
- Connections: GitHub by device flow and 1Password by service-account token, held by the app (#236, #238, #267, #348)
- Widgets, the watch face's slots and Control Center controls the mind writes (#262, #270, #271)
- Ways in: the share sheet (#372, #380) and Shortcuts (#376)

**Other bundles**

- Womble, viewer only, on iOS 15, with the house board read-only beside the transcript (#4, #25, #375)
- The watch and the TV as viewers (#10)
- `TopoHub`: the lease, the pairing code, the device list and the LAN surfaces (#11, #41, #42); the phone's half of pairing, uncalled (#387)
- The CloudKit schema promoted to production as a checked step (#381)

**Pipeline**

- Suites run on buddybox before the push by `validate-and-push.sh`, chosen by the paths a PR changes, one suite at a time in order of arrival, a Mac lent by hand (#335, #401, #402, #404, #412, #430); every hosted job on `vm-linux` (#431)
- The Codex reviewer and its gate (#2, #156, #437); the janitor and its triage (#202, #303); device checks as one build and one topo-link issue (#361); Xcode's MCP tools, advisory (#379)

## In progress

- **topo-guest**: the emulator's code-page races (#423, #424, #425) and `touch` on a guest tmpfs (#426).
- **topo-background**: a background job the guest starts outliving iOS's budget (#452), the turn after a background resume (#447), `RoleSelector.decide()`'s unbounded first reads (#436).
- **topo-flakes**: #393, #365, #364, #349.
- #399, a suite over plain ssh getting no microphone, in PR #450.

## Next, in order

1. **What the phone does, made right.** A primary whose token refresh fails sits behind "Claude Code did not start" with no way back to sign-in (#351); a resumed guest can say the vault is unreachable while it is mounted (#357); `turn.heard` is logged several times a message (#354) and the person's turn is saved ~4 s after it (#355); `topo log` is slow and fills with polling (#356); the mirror names every non-text file as skipped at every pass (#339); the `.topo` guard is case-sensitive (#367); a picked file's hidden copy is named by pid alone (#368); a widget cue or a share's file can cross a sign-out (#370, #373); a lease timeout in the preflight fetch escapes unmapped (#321).
2. **Widgets and controls, round two.** The watch's `run` runs in place (#327); the slot picker shows each slot's title (#280); a widget's tint keeps its alpha (#282); a widget's action carries a control's `request` (#283) and can run a Shortcut or open a URL (#284).
3. **A reply on the screen, round two.** A code block or a table opens full screen (#179), a copy button on code (#217); a list item whose first block is a quote keeps its bullet (#183); an image re-read after a vault change does not wait behind the read in flight (#325).
4. **An effort selector beside the model's brain.** Nothing carries an effort to the guest, so it is the resident's launch and the harness as well as a control in the bar. No issue of its own.
5. **The mind keeps working behind another app.**
    - A spoken back-and-forth is a CallKit call: the app runs with the mic for the call's length, and hanging up ends it. For voice turns it replaces the silent keeper's 120 s ceiling (`Speaker.ceiling`).
    - The keeper is real audio: spoken progress receipts and, if chosen, ambient "working" sounds, in place of `PlayQueue`'s looping silence. A setting chooses off, receipts only or sounds; a typed session holds no audio, and the session mixes with others so other playback ducks rather than stops.
6. **Topo's ears and mouth take Daphne's gains.**
    - The ear is Parakeet Ultra (`AsrModelVersion.ultra`, a pinned entry in `models.json`) in place of v2, the spotter and `Vocabulary` unchanged. On Sam's 22 bench recordings through Daphne's path it measured WER 0.027 against v2's 0.059 (samdu/daphne-assistant#205). The encoder is ~595 MB against 442 MB; first load and resident memory on a phone are unmeasured.
    - Pocket's Mimi encoder pinned `.cpuOnly` beside the decoder (`PocketTtsComputeUnits.mimiEncoder`), closing the last stage whose default can reach the GPU.
    - A reply's opening piece ends at its first comma, semicolon or dash past 30 characters, not only at a sentence end (samdu/daphne-assistant#207): on Daphne's eval the piece was ready a median 0.28 s sooner on the 9 of 45 turns it changed. Measured here with `docs/perf.md`'s marks.
7. **P8: TestFlight.** The bundle's size; export compliance re-judged now that the rootfs ships OpenSSL (`docs/testflight.md` says no cryptography of its own); the App Review risk and the usage strings the tools ask for written in `docs/testflight.md`; the zone mirror's cache keyed by CloudKit environment, so a TestFlight install over a debug build never offers production a development change token (#384). Last, and not before Sam would show Topo to someone else: each step before it changes what review sees, and living on Topo day to day is what finds the steps.

**The pipeline**, beside the order: the simulator's iCloud sign-in lapses and is re-authenticated by hand (#83); `.claude/hooks/pm-guard.py` refuses code edits when the session's project dir is a linked worktree (#310); `ci-audio-lane.sh start` can leave a stale `supervisor.started` (#311); `validate-and-push.sh` gives up after 180 min while the holder is alive (#363) and its test never asserts which commit a returning suite ran at (#432); `build-for-testing` on the generic simulator destination fails on Xcode 27 (#433); `StubDNS` hides bind's errno and two runs collide on port 53 (#435); five suite-minute cuts (#439); the hosted-runner flakes recheck (#312, #308).

## Parked, and why

- **The hub as a running mind.** `TopoHub` runs no turns; the phone is the primary until the guest path is complete, since it has to stand alone as someone's only device. Full Messages access is the hub's alone (iOS gives an app no way to read or send iMessages) and waits on it.
- **Pairing.** The phone's half (`DeviceDirectory.pair`) is built and nothing calls it: no scanner, no `topo://pair` handler (`docs/pairing.md`). Phones registering a `Device` record of their own (#371) goes with it.
- **Sockets and the tunnel.** `TopoLink` carries the hub's lease probe and the LAN surfaces; the phone's probe never confirms, and there are no turn sockets and no tunnel. CloudKit is truth and works with no socket; speed comes after the mind does.
- Create arbitrary live activities
- Flic Duo button support
- **Two lease rules.** The heartbeat runs on after sign-out and a demotion, since `Harness.forget()` drops the lease without abandoning it (#148); a phone that staked primary at first launch and lost the lease to the hub is never demoted, since a stake writes no role record (#273).
- **The mascot as a movement system (#177)** and the ink he splashes on a correction (#181): the survey of game characters and NPCs comes first and is not begun. Send as a thrown plane Topo catches and reads (#330), after the composer.
- **A hidden terminal onto the guest's Claude Code (#133)**, an escape hatch for a prompt the app does not draw, once the headless path has settled.
- **Topo as a mesh peer (#277).** The topo-link issue mailbox carries device checks today; an addressable peer with an allowlist of what it runs unasked is not built.
- **On-device storage (#309, #117, #87).** The ANE compile cache, tmp at launch, the model housekeeping residue and the voice pack's ten-minute download start from a fresh measurement on the phone.
- **Ideas with no code yet:** a Topo menu the agent populates, on a long-press of the octopus (which conflicts with dragging him); what the composer's `+` opens, attachments first; Maps results as a card (#358); a contact sheet of the screen share's stills (#378); Topo walking the person through the first run himself in place of the iCloud Drive offer card (#395).
- **Small ones**, hardening with nothing failing today: a claim change attempted from the background (#90); an empty parents list left off the wire (#96); the same-folder guard compares URLs (#103); a query of mostly digits read as a number (#240); a package added to the manifest never reaches an existing fakefs (#254); the resident keeps its clock across a zone change until its next launch (#256); a look with `composer.flank.font` at 400 draws the resting keyboard mark past the pane (#337); guest transcripts under the guest's home outlive sign-out (no issue).
- **Proof gaps** a review left non-blocking, each against the PR it came from: #132, #147, #149, #153, #160, #211, #213, #221, #286, #292, #338.

## Explored, not done

- **Picture-in-picture as the way to keep working behind another app**: its tile is opaque, with no transparency.
- **swift-markdown as the parser (#179)**: everything a reply draws, tables and links included, comes from Foundation's parser, so nothing on the screen needs the dependency.
- **Kyutai's `english_2026-09_2` weights**: they convert and keep a sentence's opening word, but stop a sentence early at a number written in digits, in Kyutai's own model as in the conversion. They wait on Topo spelling numbers out before synthesis, or on later weights. `english_24l` is not converted.

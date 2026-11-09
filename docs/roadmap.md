# Topo roadmap

How the pieces fit together is in `README.md`, `docs/design.md` and the area docs it links; this file is what has been built, what is in hand, what comes next, and what is parked or was tried and left. Sam's decisions and the reasoning behind them are the wiki page [buddy-for-helen](https://github.com/samdu/memory/blob/main/wiki/buddy-for-helen.md) in `samdu/memory`; the process is `docs/process.md`. Defects are [this repo's issues](https://github.com/samdu/topo/issues); tests that fail now and then and pass on a rerun carry the [`flake`](https://github.com/samdu/topo/issues?q=is%3Aopen+label%3Aflake) label.

## Today

Topo is the phone app. Signed in through Claude Code's own login, the iPhone is the primary: the real Claude Code, pinned at 2.1.316, runs resident in an Alpine userland inside the app (iSH's arm64 emulator) with permissions bypassed, because the guest is the sandbox and what it reaches is the holes the app makes: the memory's folder mounted at `/home/topo/memory`, a loopback API proxy that passes Claude Code's own login through unchanged, a loopback tool service behind the `topo` command, a DNS forwarder onto the phone's resolver, and the internet directly. Every turn is written to the CloudKit log, which the watch, the TV, other iPhones and iPads as viewers, and Womble on old iPads read.

You talk to it by holding the jewel: Parakeet hears on the phone and Phonon reads the reply aloud as it streams, behind the lock. The memory is an Obsidian vault, local or in iCloud Drive, that the mind reads and writes. Through `topo` the mind reaches reminders, the calendar, notifications, contacts, location, HomeKit, Apple Maps, Photos, the file picker, a shared screen, AlarmKit timers, GitHub and 1Password, and writes the phone's widgets, the watch face's slots, Control Center controls and Live Activities. Things reach it from the share sheet and Shortcuts. A turn sent in front keeps running behind another app.

The Mac hub (`TopoHub`) holds the lease, shows the pairing code and serves the house's LAN surfaces; it runs no turns. Topo is on TestFlight with the internal group House and on Sam's phone; the external group Household offers a build once Beta App Review has passed one (`docs/testflight.md`, *6. Testers*), which is the third step of *Next, in order*.

## Done

Struck through: shipped, then removed, with the reason.

**The log and the roles**

- The CloudKit log, the primary lease, the device directory and the role record, against an in-memory database with CloudKit's semantics (#1, #21, #24); a whole-type read asks only for what changed (#297)
- The role at first launch from the lease record, a viewer making itself primary, a takeover that refuses a live holder (#27, #34, #36); a login found at first launch never makes a second primary beside another device's lease (#360)
- The lease runs one operation at a time with every request bounded at 4 s (#314); a fresh lease is renewed with the person's save (#306); a reply is saved when heartbeats ran late and nobody claimed (#302); a reinstalled phone is the phone it was, its name kept in the keychain (#492); the first reads at launch are bounded, and one that runs out decides nothing (#459)
- A sent message does not wait on CloudKit: the guest hears the words before the save (#323)
- A limb's turn wakes the primary by a silent push (#44)

**The guest**

- iSH vendored and built, Claude Code fetched at its pin and mounted, bash, the API proxy (#116, #119, #120, #150)
- Sign-in is `claude auth login` in the guest's unmodified Claude Code, so the resident runs as a claude.ai login and its connectors load; Topo holds no Claude token (#517). The guest's home is outside Documents, so Finder's file sharing does not show the login (#523)
- ~~Sign in with Claude as the app's own OAuth, its token in the keychain and handed to the guest~~ (removed in #517: Anthropic's terms ask that sign-in complete through Claude Code's own flow, and a handed-over token counted as an API-key login, so claude.ai connectors never loaded)
- Claude Code resident, permissions bypassed, with its lifecycle across foreground and background (#134, #138, #139), frozen across a background and thawed on return (#504); the proxy's and the tool service's listeners started again after iOS takes them (#448)
- The guest is the only brain, behind one `Brain` seam, with the transcript bridge and its ledger (#143, #186)
- The emulator: NEON for Claude Code's binary (#250, #320), the phone's time zone (#251), a tmpfs `umount` (#318), block chaining (#316), a store to translated code (#428), `mount_find` under its lock (#427); `Guest.run` bounded (#422)
- The guest on the network: its own resolver, the phone's name servers, then the DNS forwarder at `127.0.0.53` (#225, #242, #269)
- A turn behind another app under a continued-processing task, with the ~29 s grace as the floor (#440); the bridge says why a reply failed (#449); the guest is told the time iOS allows and what the way out cut short (#460); a turn takes only the lines from its input's echo (#458)
- A full context: compact now, a threshold the person and the mind set (#388)

**Voice**

- Push to talk with Parakeet on the device and the person's own vocabulary (#48, #51, #57, #85); replies read aloud behind the lock (#55, #86, #89); recovery from a media services reset (#78)
- Speakable text and code blocks cued by number (#207, #212); the voice from a reply's first sentence as it streams (#297)
- A spoken exchange behind the lock is a CallKit call, placed as the phone locks with a reply on its way and ended as Topo comes forward: the system holds the session for the call's length, so the wait is not capped while one is up, and the card's hang-up is a mute; a setting, on unless turned off (`SpokenCallSetting`, `topo voice call`). At the exchange's end away from the front the session is handed back (`notifyOthersOnDeactivation`), so what the press paused resumes. A standing call between turns — Topo reachable from a pocket a quarter of an hour after the last word — is Flic's prerequisite and is parked with it (*Parked*)
- The voice is Phonon 40m English on the device through Gradium's ptts, speaking Friendly Octopus, the bundle an essential Apple-hosted Background Assets pack for TestFlight and the App Store and in the app for the install page, which makes iOS 26 the iOS app's minimum; its temperature 0.3 unless changed, and its speed a setting and `topo voice speed` (#627); the voice's temperature as a setting (#411); noise suppression through Apple's voice processing (#385)
- The keeper is real audio: tool-class receipts (Daphne's bloops) and, under Sounds, a working bed from the release to the reply, beside the silence that holds the process; a setting of off, receipts or sounds, and `topo voice working`; a typed turn holds nothing and sounds nothing. The hand-back that lets another app's playback resume is the call's (part A of the same plan)
- A watchdog on the model downloads remakes a slow task from its resume data (#548)
- Earcons: a tone as the microphone opens, as the words go, as a reply read aloud ends and when a spoken turn fails, UI SFX's Zen sounds, a setting and `topo voice earcons`
- ~~Kokoro's `bm_buddy` blend as the voice~~ (#49; replaced in #55 by Pocket TTS on the device)
- ~~Apple speech as the ear's and the voice's fallback~~ (#48, #49; removed in #85, #86: one ear and one voice, both FluidAudio on the device, no fallback)
- ~~Pocket's `eponine` as the voice~~ (#55; `marius` in #400)
- ~~Pocket TTS through FluidAudio as the voice: `marius` at his own pace (#400), FluidAudio 0.18.2 for Pocket's 512-position cache (#397), Topo's own pack (#415), 0.5 as the temperature (#411)~~ (replaced in #627 by Phonon 40m English through Gradium's ptts)

**The chat and Topo**

- The look as a document the mind writes (#106); the glass composer and the cabochon (#104, #110, #113); the composer as one row of glass (#333); the `+` on the glass opens the menu of what the phone attaches, a file, a photo or a capture from the camera, kept and sent as a share is, and the way to share the screen (#537, #538, #539, #540)
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
- `topo activity`: a Live Activity from a progress tracker or a node tree per region, kept while Topo runs (#557); `topo timer`, an AlarmKit alarm that sounds at zero behind the lock (#592, #607)
- The composer's `+` takes a photo with the camera and starts a screen share (#553, #555)
- Connections: GitHub by device flow and 1Password by service-account token, held by the app (#236, #238, #267, #348)
- Widgets, the watch face's slots and Control Center controls the mind writes (#262, #270, #271)
- Ways in: the share sheet (#372, #380) and Shortcuts (#376)

**Other bundles**

- Womble, viewer only, on iOS 15, with the house board read-only beside the transcript (#4, #25, #375)
- The watch and the TV as viewers (#10); the watch ships inside the Topo archive as its companion (#513) and declares no `WKBackgroundModes` (#524)
- The licences and the App Review risk for a build that leaves Sam's devices, in `docs/testflight.md`, with `THIRD-PARTY` complete (#457)
- `TopoHub`: the lease, the pairing code, the device list and the LAN surfaces (#11, #41, #42); the phone's half of pairing, uncalled (#387)
- The CloudKit schema promoted to production as a checked step (#381)

**Pipeline**

- Suites run on buddybox before the push by `validate-and-push.sh`, chosen by the paths a PR changes, one suite at a time in order of arrival, a Mac lent by hand (#335, #401, #402, #404, #412, #430); every hosted job on `vm-linux` (#431); a suite with no microphone says so, and a no-mic shell is refused at preflight (#450, #509); a moving line does not run out a run's wait (#496); the Mac gate pinned to Xcode 27.2 (#527)
- The Codex reviewer and its gate (#2, #156, #437); the janitor and its triage (#202, #303); device checks as one build and one topo-link issue (#361); Xcode's MCP tools, advisory (#379); `pm-guard` denies code edits only in the main checkout (#473)
- The friction pass: what made the pipeline slow or wrong for the sessions working in it, fixed where it was met — `validate-and-push.sh`, the janitor, `mac-suite.sh`'s checks, the suite selection and the review dispatch (#630, #632–#652) — and the docs that had drifted from them (#631)

## Next, in order

The order is Sam's, 2026-11-08: "friction pass -> code audit (including tests audit) -> re-submit for review (public testflight) -> ensure claude code is able to use message threads in the guest to decrease turn latency -> new release -> mac app > new release -> move topo's ear to parakeet ultra -> work through enabling iOS' -kits". The friction pass is done (*Done*, *Pipeline*).

1. **The code audit, tests included.** A smaller, more coherent codebase with nothing in the app behaving differently: dead code out, things built twice made one, and the tests audited for what they prove, with each defect it finds fixed in a PR of its own. The proof gaps left open are its inputs (*Parked*, *Proof gaps*, and #500, #503, #521, #526), and so are the [`flake`](https://github.com/samdu/topo/issues?q=is%3Aopen+label%3Aflake)s.
2. **Re-submitted for review: TestFlight in public.** The external group Household offers a build once Beta App Review passes it (`docs/testflight.md`, *6. Testers*). Before the submission: the zone mirror's cache keyed by CloudKit environment, so a TestFlight install over a debug build never offers production a development change token (#384); the bundle's size; a tester's battery drain (#609); and a first run's downloads on a small phone (#484).
3. **Claude Code in the guest using message threads, for a faster turn.** To scope. A turn's time is measured with `docs/perf.md`'s marks; the person's save lands ~4 s after the guest hears the words (#355), and a return to the front costs ~10 CPU-s (#501).
4. **A release.**
5. **The Mac app.** To scope: the hub running a mind (*Parked*) or Topo itself on a Mac, where it draws no tooltips (#597).
6. **A release.**
7. **The ear is Parakeet Ultra** (`AsrModelVersion.ultra`, a pinned entry in `models.json`) in place of v2, the spotter and `Vocabulary` unchanged. On Sam's 22 bench recordings through Daphne's path it measured WER 0.027 against v2's 0.059 (samdu/daphne-assistant#205). The encoder is ~595 MB against 442 MB; first load and resident memory on a phone are unmeasured.
8. **iOS's kits.** To scope. Topo uses ActivityKit, AlarmKit, EventKit, HomeKit, MapKit, WidgetKit, RelevanceKit, Contacts and Core Location today.

**The pipeline**, beside the order: the simulator's iCloud sign-in lapses and is re-authenticated by hand (#83); `ci-audio-lane.sh start` can leave a stale `supervisor.started` (#311); `validate-and-push.sh`'s test never asserts which commit a returning suite ran at (#432); `build-for-testing` on the generic simulator destination fails on Xcode 27, to re-run on Xcode 27.2 (#433); #312, and #308 closed once buddybox's validate logs are checked for its flakes.

## Parked, and why

- **What the phone does, made right**, left out of Sam's ordering plan of 2026-11-08. A login that dies mid-session is not noticed, since `SignIn.refresh` runs only at guest boot (`TopoApp.swift:59`), and a primary whose guest cannot start still holds the lease (#351; its first causes went with #360 and #517); a resumed guest can say the vault is unreachable while it is mounted (#357); `turn.heard` is marked twice a message by construction, once per path in `TurnRunner.swift` (117, 296), not a leak (#354), and the person's turn is saved ~4 s after it (#355, also the third step's); `topo log` is slow and fills with polling (#356); the mirror names every non-text file as skipped at every pass (#339); the `.topo` guard is case-sensitive (#367); a picked file's hidden copy is named by pid alone (#368); a widget cue or a share's file can cross a sign-out (#370, #373); a lease timeout in the preflight fetch escapes as a raw error (`CloudKitRecordDatabase.swift:341`) and has no test (#321; its batch-conflict finding is handled by #306's `mayBeOwnClaim`).
- **Widgets and controls, round two**, left out of Sam's ordering plan of 2026-11-08: a Live Activity updated while Topo is suspended, by an APNs sender beside the pane or a `Tracker` record and its silent push, and controls in an activity (#529, whose first step shipped in #557); the watch's `run` running in place (#327); the slot picker showing each slot's title (#280); a translucent or clear tint, and the refusal naming `#RRGGBBAA` (#282, a phone run); a widget's action carrying a control's `request` (#283) and running a Shortcut or opening a URL (#284).
- **A reply on the screen, round two**, left out of Sam's ordering plan of 2026-11-08: a code block or a table full screen on a tap (#179), a copy button on code (#217; a turn's menu copies the whole turn), a list item whose first block is a quote keeping its bullet (#183), an image re-read after a vault change not waiting behind the read in flight (#325).
- **The mind keeps working behind another app**, left out of Sam's ordering plan of 2026-11-08. A turn sent in front runs on under a continued-processing task (#440); keeping that task alive while the guest's background tasks run is #472.
- **A reply's opening piece at its first comma**, left out of Sam's ordering plan of 2026-11-08, which takes the ear from Daphne's gains and not this: the piece ends at its first comma, semicolon or dash past 30 characters, not only at a sentence end (samdu/daphne-assistant#207), ready a median 0.28 s sooner on the 9 of 45 turns it changed on Daphne's eval.
- **The guest's harness as one mod**, left out of Sam's ordering plan of 2026-11-08: everything Topo fits into Claude Code from the inside, the `topo` and `apple-docs` skills, settings, hooks and prompt fragments, as one mod package installed in the guest, the tools staying CLI tools (#490, #533, #535, #536). Sam, 2026-11-04: "everything we need to jimmy into the harness should be in one mod".
- **The emulator's store racing a compile (#425)**, left out of Sam's ordering plan of 2026-11-08: a store through a writable TLB entry racing a compile that marks the page. Sam chose IC IVAU on 2026-10-23; its PR (#454) is closed unmerged with its branch `buddy/jit-ic-ivau` kept, and no work is under way.
- **The turn after a background resume (#447)**, left out of Sam's ordering plan of 2026-11-08: its fixes are merged (#448, #449, #458, #504) and it waits on a device run.
- **The hub as a running mind.** `TopoHub` runs no turns; the phone is the primary until the guest path is complete, since it has to stand alone as someone's only device. Full Messages access is the hub's alone (iOS gives an app no way to read or send iMessages) and waits on it.
- **Flic, and a standing call.** Daphne's double-press path (samdu/daphne-assistant#324) pairs a Flic through flic2lib, a binary-only xcframework whose licence forbids reverse engineering; Topo is GPL by linking the iSH fork, and the licensing question is Sam's, on the decisions pane. A call that stands between turns, which is what makes a button in a pocket reach Topo, goes with it: today a call exists from the release of a spoken press to its reply's end, and between turns iOS suspends the app by design.
- **Pairing.** The phone's half (`DeviceDirectory.pair`) is built and nothing calls it: no scanner, no `topo://pair` handler (`docs/pairing.md`). Phones registering a `Device` record of their own goes with it; #371 stays open only for a phone reinstalled beside a hub.
- **Sockets and the tunnel.** `TopoLink` carries the hub's lease probe and the LAN surfaces; the phone's probe never confirms, and there are no turn sockets and no tunnel. CloudKit is truth and works with no socket; speed comes after the mind does.
- **An effort selector beside the model's brain.** Each model runs at Anthropic's default effort. Sam's ruling of 2026-11-01: "Let's also park the effort selector on the backlog and just stick to anthropic's default effort levels for each model". Nothing carries an effort to the guest, so building it means the resident's launch and the harness as well as a control in the bar. No issue of its own.
- Flic Duo button support
- **Two lease rules.** The heartbeat runs on after sign-out and a demotion, since `Harness.forget()` drops the lease without abandoning it (#148); a phone that staked primary at first launch and lost the lease to the hub is never demoted, since a stake writes no role record (#273).
- **The mascot as a movement system (#177)** and the ink he splashes on a correction (#181): the survey of game characters and NPCs comes first and is not begun. Send as a thrown plane Topo catches and reads (#330): the composer it waited on is done (#333), and it waits on Sam to unpark it now that Topo is on TestFlight.
- **A hidden terminal onto the guest's Claude Code (#133)**, an escape hatch for a prompt the app does not draw, once the headless path has settled.
- **Topo as a mesh peer (#277).** The topo-link issue mailbox carries device checks today; an addressable peer with an allowlist of what it runs unasked is not built.
- **On-device storage (#309, #117, #87).** The ANE compile cache, tmp at launch, the model housekeeping residue and the voice pack's ten-minute download start from a fresh measurement on the phone: `scripts/perf-run.sh --fresh` and the first-run marks (#487).
- **Ideas with no code yet:** a Topo menu the agent populates, on a long-press of the octopus (which conflicts with dragging him); Maps results as a card (#358); a contact sheet of the screen share's stills (#378); Topo walking the person through the first run himself in place of the iCloud Drive offer card (#395).
- **Small ones**, hardening with nothing failing today: a claim change attempted from the background (#90); an empty parents list left off the wire (#96); the same-folder guard compares URLs (#103); a query of mostly digits read as a number (#240); a package added to the manifest never reaches an existing fakefs (#254); a zone change while the app is in front reaches the resident only at its next launch (#256); a look with `composer.flank.font` at 400 draws the resting keyboard mark past the pane (#337); guest transcripts under the guest's home outlive sign-out (no issue).
- **Proof gaps** a review left non-blocking, each against the PR it came from: #147, #149 (items 3 and 4), #153, #160, #211, #213 (three findings, and the vault mountable after sign-out), #221, #286, #292, #338.

## Explored, not done

- **Picture-in-picture as the way to keep working behind another app**: its tile is opaque, with no transparency.
- **swift-markdown as the parser**: everything a reply draws, tables and links included, comes from Foundation's parser, so nothing on the screen needs the dependency.
- **Kyutai's `english_2026-09_2` weights**: they convert and keep a sentence's opening word, but stop a sentence early at a number written in digits, in Kyutai's own model as in the conversion. They wait on Topo spelling numbers out before synthesis, or on later weights. `english_24l` is not converted.

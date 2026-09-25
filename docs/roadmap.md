# Roadmap

What is built, what comes next and in what order, what is parked, and the threads open right now. Sam's decisions and the reasoning behind them live in the wiki page [buddy-for-helen](https://github.com/samdu/memory/blob/main/wiki/buddy-for-helen.md) in `samdu/memory`; this page is the build order that follows from them. The design is `docs/design.md`, the process `docs/process.md`.

## Built and shipped

- The CloudKit log, the primary lease, the device directory and the role record (`Packages/TopoCore`), with the in-memory database the suites run against.
- Sign in with Claude (`Packages/TopoAuth`): the ordinary tokens and the guest's long-lived token, both in the device keychain.
- The phone harness (`Packages/TopoTurn`): the outbox and the row, the nonce contract, the answering loop, the silent push for a limb's turn.
- The guest: iSH's arm64 kernel in the app's process, Alpine with bash, Claude Code pinned and mounted, the API proxy on loopback, the resident process with its lifecycle across foreground and background (`Packages/TopoUserland`, `Packages/TopoProxy`).
- The transcript bridge: the guest is the only brain, the ledger lines its conversation up with the log across crashes, and an unfinished turn is asked again by hand.
- Voice: push to talk on Parakeet, replies read on Pocket TTS, both downloaded by the app and held behind the lock.
- The memory as an Obsidian vault: local or in iCloud Drive, mirrored both ways under file coordination, moved between homes with one commit point.
- The look as a document (`look.json`), the glass composer that goes short under the keyboard, the badge, and the transcript drawn by phone, watch and television.
- Topo on the glass: the pixel engine, poses from the guest's events, a calm idle with yoga, facing by side, roaming the chat without juddering under a turn.
- The model picker, Tuning (placement and pin in every build, sliders in debug), diagnostics, About with the GPL text and the source commit.
- Womble for iOS 12 devices, viewer only.
- The hub app skeleton (`TopoHub`), holding the lease and showing the pairing code.
- CI: the three-job PR check with the audio lane, the Codex reviewer and its gate, the simulator runbook, OTA builds from `samdu/experiments`.

## Next, in order

1. **Topo's placement, #165.** Roam, glass or pinned by a long-press drag. Reviewed, device-checked, CI green; waits only on Sam's word to merge, since Codex is out until 27 September and automerge reads the red reviewer job.
2. **Markdown in the transcript, #164.** Topo's replies carry fenced code and lists that draw as plain text today; this is the first thing a person notices after the mascot, and it touches nothing but `TranscriptView`, so it is cheap while the transcript is fresh in mind.
3. **P5b: delete the Messages API.** `MessagesAPI`, `MessagesAPIBrain` and the model call in `TurnRunner` are compiled only for the suites; removing them closes #129 and takes a whole class of "falls back to the API" defects off the review's list. Before P6, because P6 adds a mount the bridge suites will need to cover and they should not still be running over two brains.
4. **P6: the memory as a mount.** The vault folder into the guest, eviction handled through the fork's file coordination, the mirror untouched. This is what makes the mind able to read and write its own notes, and it is the last hole before P7 adds any more.
5. **P7: the phone's own tools.** A loopback tool service and a small `topo` CLI in the guest (calendar, reminders, contacts, location, notify), found by a skill rather than paid for per turn. After P6, since notes are the tool everything else writes into.
6. **P8: TestFlight with the guest.** Bundle size, export compliance re-judged now that a rootfs with OpenSSL ships, the App Review risk written down (`docs/testflight.md`). Last because each step before it changes what review sees.

## Parked, and why

- **The hub as a running mind.** `TopoHub` holds the lease and shows the pairing code but runs no turns; the phone is the primary until the guest path is complete, because the phone is the device Helen has.
- **Sockets and the tunnel** (`Packages/TopoLink` beyond the LAN probe). CloudKit is truth and works with no socket; speed comes after the mind does.
- **The house board** (`docs/board.md`). Designed, with `TopoBoard` in place; no screen draws it until one person's mind is worth sharing a wall with.
- **A settings button replaced by a long press on Topo.** Sam's word: never mind the settings button; the badge stays.
- **A hidden terminal onto the guest's Claude Code, #133.** Useful for debugging; not a feature.
- **Resuming a spoken reply after an interruption.** Deliberately not built; a reply cut by a call carries on, a reply interrupted by anything else is said again by hand.

## Open threads

### Pull requests

- **#165** at `59056be`: suites, `test` and `review_gate` green; Codex failed on its usage limit; merge is `gh api -X PUT repos/samdu/topo/pulls/165/merge -f merge_method=squash -f sha=<head>` on Sam's word. One device line unticked and skippable: a `placement: glass` set in the vault's `look.json` rather than Tuning still glides him at launch, because the vault's look is read only after a sync.

### Deferred proof gaps

- **#160** (Topo roams) and **#154** (glass under the keyboard): test gaps the sweeps deferred rather than fixed.
- **#149**: five corner cases in the transcript bridge from #143's last Codex read, merged over by override.
- **#147**, **#132**, **#153**: tests that bind what they should not or leave a path untested.
- **#161**: the chat draws empty until the first CloudKit read returns; a first-run progress plan has not been written.
- **#128**: the first-run screen shows after sign-in when the log already has turns.
- **#148**: the lease's heartbeat runs on after sign-out.
- **#135**: Claude Code in the guest sometimes exits 0 at start with no output, about one start in eight; the resident restarts, so it costs a resume.
- **#87**: the voice pack takes about ten minutes to download on the phone.
- Guest transcripts under the guest's home are not wiped at sign-out; no issue yet.

### Flakes on CI

#91, #122, #124, #126, #127, #141, #146, #159: each is a timing bound on a cold runner, noted rather than fixed. `topo_unit` has grown to about 27 minutes on the full lane and is now the long pole.

### The device-check queue

- Sam's phone (`83FAFEC2-7326-5E79-A186-AB8E1B0A32E3`) is not reachable from buddybox for a direct install; every device check goes through the OTA page `~/github/experiments/ota/publish-topo.sh <ref>` builds, which is a Release build with no debug sliders and no Haiku pin. A debug build with the Tuning sliders waits on the phone being reachable.
- #165's vault-look line, above, if Sam wants it checked.
- The TestFlight steps in `docs/testflight.md` all need Sam's Apple account and none has been started.

### The review pipeline

- Codex (the CI reviewer) is out on its ChatGPT usage limit until 27 September; stand-in reviews are the `adversarial-reviewer` agent, and their verdicts are in each plan's ledger under `~/Desktop/topo-plans/progress-*.md`.
- `advisorModel: fable` is set in buddybox's `~/.claude/settings.json` for engineer sessions; no engineer session has yet had the Advisor tool, so the experiment has produced no data.
- Automerge skips while any job in the PR-validate run is red, the reviewer job included, so a Codex outage means every merge is by hand.
- The topo-status poller trips GitHub's secondary rate limit; `gh` calls fail with a 403 for a few minutes at a time.

# Tests and the PR check

Every suite's own description sits with the code it holds (the guest's in `docs/guest.md`, the mascot's in `docs/mascot.md`, the packages' in `docs/cloudkit.md`). Running the app signed in, the microphone press, the audio lane and the talk lane are `docs/simulator.md`.

## The debug launch environment

A simulator is signed in from its launch environment, not by hand: `Apps/Client/DebugRun.swift` (all of it behind `#if DEBUG`) takes a Claude Code setup token from `TOPO_CLAUDE_SETUP_TOKEN` and writes it to the store as a finished sign-in, puts a turn on the harness's line from `TOPO_DEBUG_OUTBOX` (empty clears it) so a launch can be the relaunch that finds one owed, and takes one turn from `TOPO_DEBUG_SEND` through the ordinary harness, waiting first for the guest to be ready (`guest: waiting: …`, then `guest: ready`), printing each step prefixed `[topo-debug]`, each pose Topo takes from the guest's turn (`mascot: turn began for <turn>, process P, …`, `mascot: …`, `mascot: turn gone for <turn>, …`, naming the turns the guest turn answers), and the reply as `reply to <nonce> in run <run> from session <id>, process <pid>: <text>`.

## The PR check

The PR check itself is three macOS jobs at once — the Topo scheme's test action split by test selection into the UI tests (`topo_ui`) and everything else (`topo_unit`), and the scripts' tests, the packages, Womble and the watch, TV, Release and hub builds (`others`) — behind one gate job on ubuntu, `test`, which the merge waits on; the reviewer waits on `topo_unit` and `others` alone and runs beside `topo_ui`. Three of the free plan's five concurrent macOS jobs, so a second PR validating at once queues one job rather than all of it.

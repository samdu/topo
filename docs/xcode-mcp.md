# Xcode's tools and Apple's skills

Xcode 27 serves its own tools to an agent over MCP and ships Apple-written skills beside them. Here they are advisory: a screenshot, a preview, a look at what the app did on a simulator. Nothing that decides anything depends on them.

## The one rule

**Nothing in the merge gate reads the bridge.** The gate is the suites `scripts/mac-suite.sh` runs under `xcodebuild` and `swift test`, with `scripts/ci-require-tests.sh` reading each result bundle, and the review behind them (`docs/testing.md`, `docs/process.md`); a TestFlight upload is `scripts/archive-upload.sh`. No script, workflow or hook in this repository calls `mcpbridge` or `mcp-server`, and a build or test run an agent made through `BuildProject`, `RunAllTests` or `RunSomeTests` is evidence of nothing in a PR's Proof: the claim there is the suite's. The headless server is an Apple early preview whose permissions can need Xcode relaunched or the Mac rebooted to apply, so it is allowed to be down, and a session that finds it down carries on without it.

## The server

`.mcp.json` registers one server, `xcode`, as `xcrun mcpbridge` over stdio, which is the registration Apple's own plugin carries. It is the only registration: none is kept at user scope, so `claude mcp get xcode` names the project file as its source. A session started in the repository or a worktree of it gets the tools as `mcp__xcode__*`, once Claude Code's own approval of a project's servers has been given for that checkout (an interactive session is asked the first time; until then `claude mcp list` shows the server as pending approval), which is a different gate from the server's approval of the agent below; on a host with no Xcode the server fails to connect and nothing else changes. The command is not wrapped (no `timeout`, no shell), because the server approves the signed process that starts the bridge, and a wrapper is what would be approved in the agent's place.

The bridge talks to Xcode's headless server (`xcrun mcp-server`), which runs with no Xcode window and starts on the first call. `xcrun mcp-server status` prints what it permits. The Mac needs headless mode on, the two folders permitted and the agent approved, each with `sudo`:

```sh
sudo xcrun mcp-server enable                                          # headless mode on
sudo xcrun mcp-server allow-folder "$HOME/github/topo" --always       # the checkout
sudo xcrun mcp-server allow-folder "$HOME/github/.worktrees" --always # every worktree
sudo xcrun mcp-server approve <id> --always                           # the agent, by the id `status` lists as pending
```

A folder grant alone lets no agent in: `XcodeOpenWorkspace` from an agent the server has not approved fails with "waiting for the user to approve this request" and leaves a pending approval for that agent (`Claude Code — signed Q6L2SF6YDW com.anthropic.claude-code`). A pending request lapses, so the id to approve is the one `status` lists at that moment. The approval is recorded against the signature, not against a session. `enable --unsafe-always-allow-all-agents` is never used here: it allows every agent on the Mac, and buddybox runs other people's work.

A session opens its own worktree's project (`XcodeOpenWorkspace` with the absolute path of `Topo.xcodeproj`) and names it as `workspaceIdentifier` in each call after, since the server holds every session's workspaces at once; it closes it (`XcodeCloseWorkspace`) when it is done. The project builds only after `scripts/build-ish.sh` has made the guest's framework in that worktree, as under `xcodebuild`.

## The agent's simulator

`RunProject`, `RunAllTests` and `RunSomeTests` boot, install and launch on the workspace's active run destination, and a `DeviceInteraction*` session on the device it is given. The validation suites and `scripts/simulator-run.sh` each count on a device nobody else is using (CLAUDE.md, *Working here*), so everything an agent runs through the bridge goes to one device kept for it, **`Topo Agent`**, an iPhone 17 on the iOS runtime `scripts/mac-suite.sh` pins:

```sh
xcrun simctl create "Topo Agent" com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcrun simctl list devices | grep "Topo Agent"    # its udid
```

- **Take it first, release it last.** It is one device, so a session reserves it before anything runs on it: `scripts/agent-simulator.sh take` prints its udid and records the session as its holder, and `scripts/agent-simulator.sh release` shuts the device down and gives it up. The reservation names the session's own `claude` process and stands for as long as that process lives, so it outlasts the shells a session runs its commands in and falls to the next `take` when the session is gone. A session's subagents are that process too, so they share its reservation, and one that releases it releases it for all of them. `take` exits 3 and names the holder when another session has it (1 is a fault it prints: no such device, or one that would not shut down); that session does without for now: it builds and reads through the bridge, runs nothing, and neither waits nor boots the device. `scripts/agent-simulator.sh holder` says who has it.
- **Switch first, and read the answer.** Straight after `XcodeOpenWorkspace`, before any tool that runs anything, `XcodeSwitchRunDestination` to the `displayTitle` `XcodeListRunDestinations` gives for `Topo Agent`, and check the `activeDestinationDisplayTitle` it returns: the tool refuses an ineligible destination and reports what Xcode resolved, which is not always what was asked for. A device session is given the udid as its `deviceIdentifier`, never the name, which is matched by best candidate on a Mac with other simulators named for Topo.
- No other script is pointed at it: it is never `DEVICE` for `scripts/simulator-run.sh`, which erases the device it is given on `--erase`, and `mac-suite.sh` makes and deletes its own. It is signed into nothing, so a run on it is a signed-out app.
- `DeviceInteractionEndSession` ends each device session; Apple's skill calls an open one resource-heavy.
- **A synthesized touch is a claim until the screen says otherwise.** `DeviceInteractionSynthesize` returns the paths of a screenshot and a UI hierarchy taken after the event. Read them and find the change the interaction was for (the row that appeared, the field that holds the text, the button that changed state) before saying it happened; a tap on a disabled control or a missed coordinate returns as cleanly as one that landed. A step with no change to point at is reported as not done.

## Apple's skills

Apple's skills are loaded from Xcode's own plugin, not kept in this repository: they are Apple's, under Xcode's licence, which does not allow them to be republished, and the repository is public. A session that wants them is started with the plugin Xcode writes for its build:

```sh
claude --plugin-dir "$(xcrun agent plugin path --plugin-format claude)"
```

That is `xcode-integration`, fifteen skills under the names `xcode-integration:<skill>`, written to `~/Library/Developer/Xcode/CodingAssistant/ExportedPlugins/<build>/claude`, so the skills are always those of the Xcode the Mac has selected and a new Xcode needs nothing done. The plugin registers the same `xcode` server as `.mcp.json`, and a session with both has it once. `xcrun agent skills export` writes ten of the fifteen as plain directories; nothing here uses it.

Those of use to Topo: `swiftui-specialist` and `swiftui-whats-new-27` when writing SwiftUI against SDK 27, `app-intents-specialist` and `app-intents-whats-new-27` for the Shortcuts and widget intents, `modernize-tests` for XCTest outside the UI suites, `device-interaction` (a subagent skill, over the tools above), and the three accessibility auditors (`accessibility-voiceover-specialist`, `accessibility-dynamic-type-specialist`, `accessibility-sufficient-contrast-specialist`), which are run as a review pass and gate nothing. Several declare that they supersede the model's training; none supersedes this repository's CLAUDE.md or `docs/`.

## Crash and field data

`GetTopCrashIssues`, `GetCrashIssueLogs`, `GetTopFieldPerformanceIssues` and `GetFieldPerformanceIssueLogs` read what Apple has collected from TestFlight and App Store builds: crashes, hangs, launches, disk writes, energy. They are for a triage session asking what regressed in the latest build, and for nothing in the PR check. None has been called on buddybox, so what account they need in headless mode is not established.

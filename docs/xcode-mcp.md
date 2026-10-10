# Xcode's tools and Apple's skills

Xcode 27 serves its own tools to an agent over MCP and ships Apple-written skills beside them. Here they are advisory: a screenshot, a preview, a documentation search, a look at what the app did on a simulator. Nothing that decides anything depends on them.

## The one rule

**The merge gate is `xcodebuild` and `scripts/ci-require-tests.sh`, and nothing else.** A suite passes when `scripts/mac-suite.sh` ran it under `xcodebuild` and `ci-require-tests.sh` read its result bundle (`docs/testing.md`); a TestFlight upload is `scripts/archive-upload.sh`. No script, workflow, hook or status reads anything from `mcpbridge`, and a build or test run an agent made through `BuildProject`, `RunAllTests` or `RunSomeTests` is evidence of nothing in a PR's Proof: the claim there is the suite's. The headless server is an Apple early preview whose permissions can need Xcode relaunched or the Mac rebooted to apply, so it is allowed to be down, and a session that finds it down carries on without it.

## The server

`.mcp.json` registers one server, `xcode`, as `xcrun mcpbridge` over stdio, which is the registration Apple's own plugin carries. A session started in the repository or a worktree of it gets the tools as `mcp__xcode__*`; on a host with no Xcode the server fails to connect and nothing else changes. The command is not wrapped (no `timeout`, no shell), because the server approves the signed process that starts the bridge, and a wrapper is what would be approved in the agent's place.

The bridge talks to Xcode's headless server (`xcrun mcp-server`), which runs with no Xcode window and starts on the first call. `xcrun mcp-server status` prints what it permits. Three things have to be true on the Mac, each set once with `sudo`:

```sh
sudo xcrun mcp-server enable                                          # headless mode on
sudo xcrun mcp-server allow-folder "$HOME/github/topo" --always       # the checkout
sudo xcrun mcp-server allow-folder "$HOME/github/.worktrees" --always # every worktree
sudo xcrun mcp-server approve <id> --always                           # the agent, by the id `status` lists as pending
```

A folder grant alone lets no agent in: the first `XcodeOpenWorkspace` from an agent the server has not seen records a pending approval for that agent (`Claude Code — signed Q6L2SF6YDW com.anthropic.claude-code`), every call fails with "waiting for the user to approve" until it is approved, and the approval is recorded against that signature, not against a session. `enable --unsafe-always-allow-all-agents` is never used here: it hands every local process every project, and buddybox runs other people's work.

A session opens its own worktree's project (`XcodeOpenWorkspace` with the absolute path of `Topo.xcodeproj`) and names it as `workspaceIdentifier` in each call after, since the server holds every session's workspaces at once; it closes it (`XcodeCloseWorkspace`) when it is done. The project builds only after `scripts/build-ish.sh` has made the guest's framework in that worktree, as under `xcodebuild`.

## The agent's simulator

`DeviceInteraction*` and `RunProject` boot a simulator, install on it and launch by themselves, on whatever the active run destination is. The validation suites and `scripts/simulator-run.sh` each count on a device nobody else is using (CLAUDE.md, *Working here*), so an agent's runs go to one device kept for them, **`Topo Agent`**, an iPhone 17 on the iOS runtime `scripts/mac-suite.sh` pins:

```sh
xcrun simctl create "Topo Agent" com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-26-5
```

- Before `RunProject` or a device session, `XcodeSwitchRunDestination` to `Topo Agent` (its `displayTitle` from `XcodeListRunDestinations`), and name it as the `deviceIdentifier` of `DeviceInteractionStartWorkspaceSession`. The matching there is by best guess, so a name left out is some other session's device.
- No script is pointed at it: it is never `DEVICE` for `scripts/simulator-run.sh`, which erases the device it is given on `--erase`, and `mac-suite.sh` makes and deletes its own. It is signed into nothing, so a run on it is a signed-out app.
- It is one device, so one agent session uses it at a time, and `DeviceInteractionEndSession` ends each session: an open one holds the device and is heavy on the Mac.
- **A synthesized touch is a claim until the screen says otherwise.** `DeviceInteractionSynthesize` returns a screenshot and a UI hierarchy taken after the event. Read them and find the change the interaction was for (the row that appeared, the field that holds the text, the button that changed state) before saying it happened; a tap on a disabled control or a missed coordinate returns as cleanly as one that landed. A step with no change to point at is reported as not done.

## Apple's skills

Apple's skills are loaded from Xcode's own plugin, not kept in this repository: they are Apple's, under Xcode's licence, which does not allow them to be republished, and the repository is public. A session that wants them is started with the plugin Xcode writes for its build:

```sh
claude --plugin-dir "$(xcrun agent plugin path --plugin-format claude)"
```

That is `xcode-integration`, fifteen skills under the names `xcode-integration:<skill>`, written to `~/Library/Developer/Xcode/CodingAssistant/ExportedPlugins/<build>/claude`, so the skills are always those of the Xcode the Mac has selected and a new Xcode needs nothing done. The plugin registers the same `xcode` server as `.mcp.json`, and a session with both has it once. `xcrun agent skills export` writes ten of the fifteen as plain directories; nothing here uses it.

Those of use to Topo: `swiftui-specialist` and `swiftui-whats-new-27` when writing SwiftUI against SDK 27, `app-intents-specialist` and `app-intents-whats-new-27` for the Shortcuts and widget intents, `modernize-tests` for XCTest outside the UI suites, `device-interaction` (a subagent skill, over the tools above), and the three accessibility auditors (`accessibility-voiceover-specialist`, `accessibility-dynamic-type-specialist`, `accessibility-sufficient-contrast-specialist`), which are run as a review pass and gate nothing. Each skill declares that it supersedes the model's training; it does not supersede this repository's CLAUDE.md or `docs/`.

## Crash and field data

`GetTopCrashIssues`, `GetCrashIssueLogs`, `GetTopFieldPerformanceIssues` and `GetFieldPerformanceIssueLogs` read what Apple has collected from TestFlight and App Store builds: crashes, hangs, launches, disk writes, energy. They are for a triage session asking what regressed in the latest build, and for nothing in the PR check. They read through the account signed in to Xcode on the Mac; whether the App Store Connect API key `scripts/archive-upload.sh` uploads with is enough for them in headless mode has not been tried.

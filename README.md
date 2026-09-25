# Topo

Topo is one always-on mind per person, with every Apple device you own as a limb of it. The mind is an agent running on a Mac in your house (or, with no Mac, on the phone itself); your iPhone, iPad, watch, TV and the old iPad in the drawer are its arms: they carry the microphone, the screen, the notifications and the sensors, and they share one transcript through your own iCloud account, so nothing of yours passes through a server we run. It is open source under the GPL and not for profit; the whole design is in [docs/design.md](docs/design.md). The name is Aquaman's octopus sidekick Topo, first seen in Adventure Comics #229 (1956), written by Jack Miller and drawn by Ramona Fradon: the product is the octopus, the mind is the head, and every device is an arm.

On the phone the mind is the real Claude Code, running in an Alpine userland inside the app and signed in with your own Claude account. You talk to it by holding the microphone; the words are recognised on the phone and its replies are read aloud on the phone. Its memory is an Obsidian vault that lives in your iCloud.

## What is in the repository

- **The client** (`Apps/Client`): one SwiftUI codebase for iPhone, iPad, Apple Watch and Apple TV. Only the iOS app (iPhone and iPad) signs in and answers; the watch and TV show the transcript.
- **The hub** (`Apps/TopoHub`): the macOS menu-bar app bundling the Claude CLI, which holds the primary lease and shows the pairing code.
- **Womble** (`Womble/`): a viewer-only app for devices as old as iOS 12, which puts the transcript and the house board on a drawer iPad.
- **The packages** (`Packages/`): the logic, each with its own tests — the CloudKit log and lease (`TopoCore`), the socket layer (`TopoLink`), Sign in with Claude (`TopoAuth`), the phone harness (`TopoTurn`), the guest userland (`TopoUserland`), the guest's API proxy (`TopoProxy`) and the octopus's pixel engine (`TopoMascot`).

## Building

You need Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and, for the guest's emulator, meson, ninja and Homebrew's `llvm` and `lld`.

```bash
xcodegen generate            # Topo.xcodeproj from project.yml
scripts/build-ish.sh         # the iSH framework the iOS target links
xcodebuild -scheme Topo -destination 'generic/platform=iOS Simulator' build
```

Every target builds unsigned for a simulator. Each package's suite runs with `swift test` from its directory, offline and against an in-memory database, so nothing needs a signed-in device. Running the app signed in on a simulator is [docs/simulator.md](docs/simulator.md); putting it on a phone is [docs/install.md](docs/install.md).

## The docs

How it is meant to work:

- [docs/design.md](docs/design.md) — the design: the roles, the decisions, the order of build, the identity.
- [docs/pairing.md](docs/pairing.md) — how the devices on one Apple ID come to know each other.
- [docs/surfaces.md](docs/surfaces.md) and [docs/board.md](docs/board.md) — screens on the home network and the shared house board.

How each part is built:

- [docs/auth.md](docs/auth.md) — Sign in with Claude and the tokens.
- [docs/harness.md](docs/harness.md) — how a turn is taken on the phone.
- [docs/guest.md](docs/guest.md) — Claude Code in the userland, its proxy, and the bridge to the transcript.
- [docs/voice.md](docs/voice.md) — push to talk, the on-device ear and voice, and the model downloads.
- [docs/chat.md](docs/chat.md) — the chat screen and the `Look` it is drawn from.
- [docs/mascot.md](docs/mascot.md) — Topo the octopus on the glass.
- [docs/memory.md](docs/memory.md) — the vault on the phone.
- [docs/cloudkit.md](docs/cloudkit.md) — the log, the lease and the packages.
- [Womble/README.md](Womble/README.md) and [Design/README.md](Design/README.md) — the old-device app, and the mark and icons.

Working on it:

- [docs/process.md](docs/process.md) — how a change lands.
- [docs/testing.md](docs/testing.md) and [docs/simulator.md](docs/simulator.md) — the PR check and simulator runs.
- [docs/install.md](docs/install.md) and [docs/testflight.md](docs/testflight.md) — builds on a phone and the road to TestFlight.
- [CLAUDE.md](CLAUDE.md) — the rules and invariants every agent session in this repository works to.

## Licence

GPL-3.0 ([LICENSE](LICENSE)). Borrowed pieces and their licences are listed in [THIRD-PARTY](THIRD-PARTY).

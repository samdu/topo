# Topo

One always-on mind per person, every Apple device a limb. The design is `docs/design.md`; read it before changing anything, and keep it and this file describing what **is**, never what was or what is planned.

## Stack

- Swift and SwiftUI. One Xcode project with three targets:
  - **client**: iOS, iPadOS, watchOS, tvOS. One codebase; role (primary, viewer, limb) is decided at first launch from the CloudKit records.
  - **hub**: macOS menu-bar app bundling the Claude CLI and the channel servers. The only target that runs resident code.
  - **Womble**: the viewer-only bundle for old devices, built on old APIs so it can target back to iOS 12/13. Same CloudKit records and pairing; no mic, no models, no sign-in.
- **CloudKit is truth, sockets are speed.** State (transcript log, pairing record, primary lease) lives in the private CloudKit database; direct sockets and the punched tunnel only make live turns fast. With no socket the app still works off the records, just slower.
- The transcript is an append-only log: one record per turn, per-device sequence numbers, never overwrite. The primary lease is the one mutable record: atomic claim, 10s expiry, 5s heartbeat, probe-driven handover.
- Core logic ships as Swift packages with tests that run against a mock `CKDatabase`; no test needs a signed-in device.

## Working here

- Every change lands as a PR on a branch named `<role>/<topic>`: `lead/…`, `senior/…`, `junior/…`. The status pane assigns PRs to engineers by that prefix, so a branch without it belongs to nobody.
- Never force push.
- Prefer what exists: stdlib, then a platform framework, then an already-linked dependency, before new code or a new dependency. Nothing GPL from others ships in a bundle (App Store distribution); every borrowed piece is attributed in `THIRD-PARTY`.
- Docs describe the present state. When you change behaviour, change the doc to match; do not narrate the change.

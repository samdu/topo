# Womble

The viewer-only bundle: it shows the transcript on a device too old for the client, and does nothing else. No microphone, no models, no sign-in, and nothing it can do to the log but read it.

It does say where it is. While it is on screen it advertises itself on the local network as a surface — a screen in the house — carrying its name and the agents registered to it, so a hub can list the house without anything being written anywhere. Joining that roster takes a tap on this screen; `docs/surfaces.md` is the whole of the protocol, and `Sources/Net` is the whole of the code.

Deployment target is **iOS 12.0**, so the whole target is UIKit and completion handlers — no SwiftUI, no `async`/`await`, no scene lifecycle. Universal: iPhone and iPad, portrait and landscape.

## Building

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`, and the generated `Womble.xcodeproj` is committed, so a build needs Xcode and nothing else. Regenerate it (`xcodegen generate` in this directory) whenever `project.yml` changes, and commit both.

```
xcodebuild -project Womble/Womble.xcodeproj -scheme Womble \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Womble/Womble.xcodeproj -scheme Womble \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

There is no development team in this repository, so the build signs ad-hoc. That is not ceremony: the entitlements have to be applied for the app to hold `com.apple.developer.icloud-services`, and without it `CKContainer(identifier:)` raises the moment the app launches. A device build needs a real team.

The tests are logic tests with no host application, and they compile `Sources/Log` and `Sources/UI` directly. Nothing in either touches the container, so they run with no account and no network.

## What it reads

The CloudKit container `iCloud.zone.hexagon.topo`, private database, custom zone `Topo` — the same records `Packages/TopoCore` writes, on the Apple ID the device is already signed into. `Sources/Log` is a minimal read side of that schema: `Turn` records named `turn/<device>/<sequence>`, carrying `device`, `sequence`, `parents`, `role`, `text`, `at` and `nonce`. It does not depend on TopoCore, whose minimum is iOS 17 — six years past the devices this bundle exists for.

The read is the query plus a probe: the query index is eventually consistent, and a newest turn it has not caught up with leaves no gap behind it, so a transcript short by its tail would otherwise look complete. After the query, every device's next sequence is fetched by ID — read-your-writes — and one that exists is reported missing. This mirrors `TurnLog.read` in TopoCore.

Anything the read cannot account for is said on screen rather than hidden: a gap in a device's sequence, a parent that is not there, a record that does not parse. A fork — two devices carrying on from the same point — shows both branches and says so. A failed refresh keeps the turns already on screen; CloudKit is truth, and what it last said is still what it said.

The query asks for turns with a sequence above zero rather than for everything: CloudKit answers a match-all predicate out of the record name's index, which the development schema never marks queryable, so asking for everything is asking for an error. Sequences start at 1, so it is the same set of records by a road that exists.

It reads on launch, on returning to the foreground, and on a pull. There are no subscriptions yet, so a turn written while the screen is open appears on the next read.

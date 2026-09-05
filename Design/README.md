# Design

`topo-mark.svg` is the mark: a filled round head over eight curling arms, one mind and eight limbs, countable at icon size. It is drawn in `currentColor`, so it is white on the teal ground of an app icon and teal on a screen.

## The icons

```
swift Design/make-icons.swift        # from the repository root
```

It reads the SVG and writes every app icon in the repository: `Apps/Topo` (iOS), `Apps/TopoWatch`, `Apps/TopoHub` (macOS) and `Apps/TopoTV`, whose icon is a layered stack so it parallaxes under the remote. Everything it writes is committed, so building the apps needs nothing but Xcode; run this only when the mark or the ground changes, and commit what it writes.

The tvOS top shelf art is written at @1x only; the @2x version is several megabytes of smooth gradient for a surface nobody has seen yet, and it is one line in the script when the TV app is worth submitting.

The ground is the identity's icon gradient, `#0A8EA1` to `#005C6B` at 160°. iOS and watchOS icons are full-bleed squares because the system masks them itself; macOS draws its own rounded square with the margin that platform expects; the watch's mark sits a little smaller inside the circle it will be cut to.

## The mark on screen

`Apps/Shared/OctopusMark.swift` draws the same curves in SwiftUI, because nothing on iOS renders an SVG and the icons are made on a Mac at build time. The two are the same numbers in the same 100×100 space: change one and change the other.

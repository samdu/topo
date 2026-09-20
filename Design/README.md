# Design

`topo-mark.svg` is the mark: a filled round head over eight curling arms, one mind and eight limbs, countable at icon size. It is drawn in `currentColor`, so it is white on the stone ground of an app icon and teal on a screen.

`topo-slab.png` is the stone: one square of teal agate that every ground and every cabochon in the app is cut from. The icons are grounded on it and `Apps/Topo/Assets.xcassets/agate.imageset/agate.png` — the disc `StainedGlass` fills the microphone's and the badge's cabochons with — is a circular window onto it, so the icon on the home screen and the gem under the thumb are the same piece of stone.

It is Sam's own macro photograph of an agate slice (`~/Desktop/IMG_8321.jpeg`), redrawn as a full square slab of the same material by OpenAI's `gpt-image-2.5` through the image-edit endpoint. The photograph was soft, grainy and 512px across the disc, which is smaller than the icon it has to fill; both ends of that chain are Sam's, so `THIRD-PARTY` gains nothing.

## The icons

```
swift Design/make-icons.swift        # from the repository root
```

It reads the SVG and the slab and writes every app icon in the repository — `Apps/Topo` (iOS), `Apps/TopoWatch`, `Apps/TopoHub` (macOS) and `Apps/TopoTV`, whose icon is a layered stack so it parallaxes under the remote — and the cabochons' disc. Everything it writes is committed, so building the apps needs nothing but Xcode; run this only when the mark or the slab changes, and commit what it writes.

The tvOS top shelf art is written at @1x only; the @2x version is several megabytes of smooth gradient for a surface nobody has seen yet, and it is one line in the script when the TV app is worth submitting.

The ground is the slab, drawn to cover rather than to stretch — the top shelf is far wider than it is tall and a squashed stone is a different stone. The mark is laid on it in white under a soft shade, rather than cut into it as it is on the cabochons: a cut mark is gone by the size the home screen draws this at. iOS and watchOS icons are full-bleed squares because the system masks them itself; macOS draws its own rounded square with the margin that platform expects; the watch's mark sits a little smaller inside the circle it will be cut to.

## The mark on screen

`Apps/Shared/OctopusMark.swift` draws the same curves in SwiftUI, because nothing on iOS renders an SVG and the icons are made on a Mac at build time. The two are the same numbers in the same 100×100 space: change one and change the other.

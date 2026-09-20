# Design

`topo-mark.svg` is the mark: a filled silhouette, a round head over eight curling arms, no two the same length, countable at icon size. One closed outline in a 100×100 space, drawn in `currentColor`, so it is teal on a screen and whatever the surface under it makes of it on an icon.

It is the one copy of the curves. Everything that draws the mark reads this file — `Apps/Shared/OctopusMark.swift`, Womble's `MarkView`, `make-icons.swift` — so there is nothing to keep in step, which matters at 97 cubic segments in a way it did not at eight arms.

`topo-jelly.png` is the stone: one photograph of a slice of jelly-teal glass that every ground and every cabochon in the app is cut from. The icons are grounded on it and `Apps/Topo/Assets.xcassets/agate.imageset/agate.png` — the disc `StainedGlass` fills the microphone's and the badge's cabochons with — is a circular window onto it, so the icon on the home screen and the gem under the thumb are the same piece of stone. The badge's is that stone under `Theme.secondary`, a cast rather than a second photograph.

Both are Sam's, made with OpenAI's `gpt-image-2.5`, so `THIRD-PARTY` gains nothing.

## The two cuts

`make-icons.swift` holds two windows on the stone, `groundCut` and `gemCut`, as fractions of the picture. Each is the largest of its shape — a square for the grounds, a disc for the cabochons — that contains no part of the card the jelly was photographed on, placed where the stone's light varies most. Both halves of that matter: the jelly's middle is a flat wash, so the largest crop centred on the picture is the least interesting part of it; and a crop that clips the card carries a sliver of cream into an icon.

They are constants because finding them is a search over the photograph rather than something to redo per render. If the stone is ever replaced, the search is: threshold the alpha, **fill the enclosed holes** — the brightest highlights key within a few levels of the card, and one transparent pixel at the centre caps every crop that has to clear it — then for each candidate size, the positions where the shape fits, and among those the one whose luminance variance is highest.

## The icons

```
swift Design/make-icons.swift        # from the repository root
```

It reads the SVG and the stone and writes every app icon in the repository — `Apps/Topo` (iOS), `Apps/TopoWatch`, `Apps/TopoHub` (macOS) and `Apps/TopoTV`, whose icon is a layered stack so it parallaxes under the remote — and the cabochons' disc. Everything it writes is committed, so building the apps needs nothing but Xcode; run this only when the mark or the stone changes, and commit what it writes.

The tvOS top shelf art is written at @1x only; the @2x version is several megabytes of smooth gradient for a surface nobody has seen yet, and it is one line in the script when the TV app is worth submitting.

The ground is the stone, drawn to cover rather than to stretch — the top shelf is far wider than it is tall and a squashed stone is a different stone. The mark is cut into it through the same treatment the app presses its marks with (`Look.Press`: a wall of 6/512 of the stone, dark at the top of a stroke and light at its foot, over a floor a shade under the surface), so the icon is the same object as the gem. The one exception is the tvOS front layer, which is the mark laid on in white under a soft shade: a layer that floats above the stone has no stone to cut into. iOS and watchOS icons are full-bleed squares because the system masks them itself; macOS draws its own rounded square with the margin that platform expects; the watch's mark sits a little smaller inside the circle it will be cut to.

The four `press*` constants in the script are `Look.Press`'s values written out, because `Look.swift` is Swift the app compiles and not something a script can import.

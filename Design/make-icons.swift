#!/usr/bin/env swift
// Renders the app icons, and the stone the app's cabochons are cut from,
// from Design/topo-mark.svg and Design/topo-jelly.png.
//
//   swift Design/make-icons.swift        # from the repository root
//
// The SVG is the source: this reads its paths rather than holding a second
// copy of the mark, so a change to the drawing is a change in one place.
// Everything it writes is committed, so nobody needs Xcode to run this to
// build the app — only to change the mark.
//
// The ground is the app's own stone — `Design/topo-jelly.png`, which the
// microphone's and the badge's cabochons are cut from too — and the mark is cut
// into it through the same treatment the app presses its marks with, so the icon
// on the home screen is the same object as the gem under the thumb. iOS and
// watchOS icons are full-bleed squares (the system masks them), macOS draws its
// own rounded square with the margin that platform expects, and tvOS is a
// layered stack: ground behind, mark in front, so it parallaxes under the
// remote. That front layer is the one place the mark is laid on in white rather
// than cut in — a layer that floats above the stone has no stone to cut into.

import AppKit
import CoreImage
import Foundation

// MARK: - The mark

/// One `d` attribute: a move, then cubic segments, then the close that makes the
/// outline a silhouette. The mark uses no other commands, so this reads what is
/// there rather than all of SVG.
func path(fromD d: String) -> CGPath {
    let numbers = d.split(whereSeparator: { " ,MCZ".contains($0) }).compactMap { Double($0) }
    guard numbers.count >= 8, (numbers.count - 2) % 6 == 0 else {
        fatalError("Design/topo-mark.svg: not a move-then-curves path: \(d)")
    }
    let path = CGMutablePath()
    path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
    for start in stride(from: 2, to: numbers.count, by: 6) {
        path.addCurve(to: CGPoint(x: numbers[start + 4], y: numbers[start + 5]),
                      control1: CGPoint(x: numbers[start], y: numbers[start + 1]),
                      control2: CGPoint(x: numbers[start + 2], y: numbers[start + 3]))
    }
    path.closeSubpath()
    return path
}

func matches(_ pattern: String, in text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range(at: 1), in: text)!])
    }
}

/// The mark in its own 100×100 space: one closed outline, filled.
func mark(fromSVG svg: String) -> CGPath {
    guard let d = matches("<path d=\"([^\"]+)\"", in: svg).first else {
        fatalError("Design/topo-mark.svg: no path")
    }
    return path(fromD: d)
}

// MARK: - Drawing

/// The stone: one photograph of a slice of jelly-teal glass, which every icon
/// is grounded on and both cabochons are cut from, so the icon on the home
/// screen and the gem under the thumb are one object.
let jelly: NSImage = {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Design/topo-jelly.png")
    guard let image = NSImage(contentsOf: url) else {
        fatalError("Design/topo-jelly.png: not readable")
    }
    return image
}()

/// A window on the stone, in fractions of it, measured from the top-left as the
/// picture is written.
struct Cut {
    let cx: CGFloat
    let cy: CGFloat
    let side: CGFloat
}

/// The two cuts. Each is the largest of its shape that holds no card at all,
/// placed where the stone's light varies most: the middle of the jelly is a flat
/// wash, and a crop centred on the picture lands in it. They are constants here
/// because finding them is a search over the photograph, run once
/// (`Design/README.md`), and what the search found is what ships.
let groundCut = Cut(cx: 0.5024, cy: 0.4928, side: 0.5750)
let gemCut = Cut(cx: 0.5064, cy: 0.5112, side: 0.7775)

/// The stone covering a rectangle, cropped rather than stretched: the top shelf
/// is far wider than it is tall and a squashed stone is a different stone. What
/// is narrowed is the window and never the destination, so no part of the card
/// the jelly was photographed on can reach an icon however wide it is.
func fill(_ rect: NSRect, from cut: Cut) {
    let width = jelly.size.width, height = jelly.size.height
    let aspect = rect.width / rect.height
    let window = NSSize(width: cut.side * width * min(aspect, 1),
                        height: cut.side * height / max(aspect, 1))
    jelly.draw(in: rect,
               from: NSRect(x: cut.cx * width - window.width / 2,
                            // The cuts are measured downwards and Quartz counts up.
                            y: (1 - cut.cy) * height - window.height / 2,
                            width: window.width, height: window.height),
               operation: .sourceOver, fraction: 1)
}

// MARK: - The cut

/// `Look.Press`, which is what the app cuts both its marks with: the wall's
/// width as a share of the stone it is cut into, the dark wall at the top of a
/// stroke and the light one at its foot, how far a wall is softened as a share
/// of its own width, and how much of the shade lies over the floor. Held here
/// rather than read from `Look.swift`, which is Swift the app compiles and not
/// something a script can import; the two are checked against each other by
/// `IconTests`.
let pressWall: CGFloat = 6.0 / 512
let pressSoften: CGFloat = 0.35
let pressFloor: CGFloat = 0.3
let pressShade: CGFloat = 0.62
let pressCatch: CGFloat = 0.62

/// One wall of the cut as a mask: the mark, less the mark moved by the wall's
/// width, softened. Moved down the screen that is the side facing away from the
/// light; moved up, the side that catches it.
func wall(_ mark: CGPath, by dy: CGFloat, size: CGSize, soften: CGFloat) -> CGImage? {
    guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.addPath(mark)
    context.fillPath()
    context.setBlendMode(.copy)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    var moved = CGAffineTransform(translationX: 0, y: dy)
    if let offset = mark.copy(using: &moved) {
        context.addPath(offset)
        context.fillPath()
    }
    guard let band = context.makeImage() else { return nil }
    guard soften > 0.4, let filter = CIFilter(name: "CIGaussianBlur") else { return band }
    filter.setValue(CIImage(cgImage: band), forKey: kCIInputImageKey)
    filter.setValue(soften, forKey: kCIInputRadiusKey)
    guard let blurred = filter.outputImage else { return band }
    let frame = CGRect(origin: .zero, size: size)
    return CIContext().createCGImage(blurred, from: frame, format: .L8,
                                     colorSpace: CGColorSpaceCreateDeviceGray()) ?? band
}

/// The mark cut into the stone, the way `Pressed` cuts it: the mark's own shape
/// filled with the stone a shade under the stone around it, the wall at the top
/// of every stroke dark where it faces away from the light, and the wall at its
/// foot catching it.
func engrave(_ cg: CGContext, mark: CGPath, size: CGSize, ground cut: Cut) {
    let frame = CGRect(origin: .zero, size: size)
    let width = min(size.width, size.height) * pressWall

    // The floor: the same stone in the same place, under the shade that sets it
    // below the surface.
    cg.saveGState()
    cg.addPath(mark)
    cg.clip()
    fill(frame, from: cut)
    cg.setFillColor(CGColor(gray: 0, alpha: pressFloor))
    cg.fill(frame)
    cg.restoreGState()

    // The two walls. Quartz counts y upwards, so the wall at the top of a stroke
    // is the band left when the mark moved *down* is taken out of it.
    for (dy, colour) in [(-width, CGColor(gray: 0, alpha: pressShade)),
                         (width, CGColor(gray: 1, alpha: pressCatch))] {
        guard let band = wall(mark, by: dy, size: size, soften: width * pressSoften) else { continue }
        cg.saveGState()
        cg.clip(to: frame, mask: band)
        cg.setFillColor(colour)
        cg.fill(frame)
        cg.restoreGState()
    }
}

/// What holds a laid mark off the stone's bright band: a soft shade under it,
/// measured as a share of the icon's own side so every size is one picture. Only
/// the tvOS front layer is laid on; everything else is cut in.
let markShadowOffset: CGFloat = 0.008
let markShadowBlur: CGFloat = 0.012
let markShadowAlpha: CGFloat = 0.35

enum Ground {
    /// The whole square, for the platforms that mask the icon themselves.
    case full
    /// A rounded square with a margin, which is what a Mac icon is.
    case rounded(margin: CGFloat)
    /// Nothing, for a layer that sits over another.
    case none
}

func render(size: CGSize, ground: Ground, markHeight: CGFloat, markPath: CGPath) -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                     pixelsHigh: Int(size.height), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("no bitmap at \(size)")
    }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.setShouldAntialias(true)

    switch ground {
    case .full:
        fill(NSRect(origin: .zero, size: size), from: groundCut)
    case .rounded(let margin):
        let inset = min(size.width, size.height) * margin
        let box = NSRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
        let radius = box.width * 0.225
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).addClip()
        fill(box, from: groundCut)
        NSGraphicsContext.restoreGraphicsState()
    case .none:
        break
    }

    // The mark, centred on its own ink rather than on its 100×100 box, and
    // flipped: SVG counts y downwards and Quartz counts it up.
    let ink = markPath.boundingBoxOfPath
    let scale = markHeight / max(ink.width, ink.height)
    let place = CGAffineTransform.identity
        .translatedBy(x: (size.width - ink.width * scale) / 2 - ink.minX * scale,
                      y: (size.height - ink.height * scale) / 2 - ink.minY * scale)
        .scaledBy(x: scale, y: scale)
    let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
    var transform = place.concatenating(flip)
    guard let placed = markPath.copy(using: &transform) else { fatalError("the mark did not place") }

    switch ground {
    case .full, .rounded:
        // Cut into the stone, through the treatment the app presses both its
        // marks with, so the icon and the gem are the same object.
        engrave(cg, mark: placed, size: size, ground: groundCut)
    case .none:
        // A layer that floats above the stone has no stone to cut into, so the
        // tvOS front layer is the mark laid on in white, held off whatever is
        // behind it by a shade.
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -size.height * markShadowOffset),
                     blur: size.height * markShadowBlur,
                     color: NSColor.black.withAlphaComponent(markShadowAlpha).cgColor)
        cg.setFillColor(NSColor.white.cgColor)
        cg.addPath(placed)
        cg.fillPath()
        cg.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    return png
}

// MARK: - Writing

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svg = try String(contentsOf: root.appendingPathComponent("Design/topo-mark.svg"), encoding: .utf8)
let markPath = mark(fromSVG: svg)

func write(_ data: Data, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url)
    print("  \(path)")
}

func write(json: String, _ path: String) throws {
    try write(Data((json + "\n").utf8), path)
}

func square(_ pixels: Int, ground: Ground, mark fraction: CGFloat) -> Data {
    render(size: CGSize(width: pixels, height: pixels), ground: ground,
           markHeight: CGFloat(pixels) * fraction, markPath: markPath)
}

print("iOS")
try write(square(1024, ground: .full, mark: 0.62), "Apps/Topo/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
try write(json: """
{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", "Apps/Topo/Assets.xcassets/AppIcon.appiconset/Contents.json")

print("watchOS")
// The watch masks its icon to a circle, so the mark sits a little smaller.
try write(square(1024, ground: .full, mark: 0.54), "Apps/TopoWatch/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
try write(json: """
{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "watchos",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", "Apps/TopoWatch/Assets.xcassets/AppIcon.appiconset/Contents.json")

print("macOS")
var macImages: [String] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try write(square(pixels, ground: .rounded(margin: 0.10), mark: 0.46),
                  "Apps/TopoHub/Assets.xcassets/AppIcon.appiconset/\(name)")
        macImages.append("""
            {
              "filename" : "\(name)",
              "idiom" : "mac",
              "scale" : "\(scale)x",
              "size" : "\(points)x\(points)"
            }
        """)
    }
}
try write(json: """
{
  "images" : [
\(macImages.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", "Apps/TopoHub/Assets.xcassets/AppIcon.appiconset/Contents.json")

print("tvOS")
let brand = "Apps/TopoTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
try write(json: """
{
  "assets" : [
    {
      "filename" : "App Icon.imagestack",
      "idiom" : "tv",
      "role" : "primary-app-icon",
      "size" : "400x240"
    },
    {
      "filename" : "App Icon - App Store.imagestack",
      "idiom" : "tv",
      "role" : "primary-app-icon",
      "size" : "1280x768"
    },
    {
      "filename" : "Top Shelf Image.imageset",
      "idiom" : "tv",
      "role" : "top-shelf-image",
      "size" : "1920x720"
    },
    {
      "filename" : "Top Shelf Image Wide.imageset",
      "idiom" : "tv",
      "role" : "top-shelf-image-wide",
      "size" : "2320x720"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", "\(brand)/Contents.json")

/// A tvOS icon is a stack of layers, drawn apart from each other as the
/// remote moves: the ground behind, the mark in front.
func imageStack(_ name: String, width: Int, height: Int, scales: [Int]) throws {
    try write(json: """
    {
      "info" : { "author" : "xcode", "version" : 1 },
      "layers" : [
        { "filename" : "Front.imagestacklayer" },
        { "filename" : "Back.imagestacklayer" }
      ]
    }
    """, "\(brand)/\(name).imagestack/Contents.json")
    for (layer, ground, fraction) in [("Back", Ground.full, CGFloat(0)), ("Front", Ground.none, CGFloat(0.55))] {
        var images: [String] = []
        for scale in scales {
            let file = "\(layer.lowercased())\(scale == 2 ? "@2x" : "").png"
            let data = render(size: CGSize(width: width * scale, height: height * scale), ground: ground,
                              markHeight: CGFloat(height * scale) * fraction, markPath: markPath)
            try write(data, "\(brand)/\(name).imagestack/\(layer).imagestacklayer/Content.imageset/\(file)")
            images.append("""
                { "filename" : "\(file)", "idiom" : "tv", "scale" : "\(scale)x" }
            """)
        }
        try write(json: """
        { "info" : { "author" : "xcode", "version" : 1 } }
        """, "\(brand)/\(name).imagestack/\(layer).imagestacklayer/Contents.json")
        try write(json: """
        {
          "images" : [
        \(images.joined(separator: ",\n"))
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """, "\(brand)/\(name).imagestack/\(layer).imagestacklayer/Content.imageset/Contents.json")
    }
}

try imageStack("App Icon", width: 400, height: 240, scales: [1, 2])
try imageStack("App Icon - App Store", width: 1280, height: 768, scales: [1])

/// The top shelf is what tvOS shows above a focused app. It is written at
/// @1x only: the @2x art is 4640 points across, several megabytes of smooth
/// gradient in the repository for a surface no Topo user has seen yet, and
/// it is one line here when the TV app is worth submitting.
func topShelf(_ name: String, width: Int, height: Int) throws {
    var images: [String] = []
    for scale in [1] {
        let file = "top-shelf\(scale == 2 ? "@2x" : "").png"
        let data = render(size: CGSize(width: width * scale, height: height * scale), ground: .full,
                          markHeight: CGFloat(height * scale) * 0.5, markPath: markPath)
        try write(data, "\(brand)/\(name).imageset/\(file)")
        images.append("""
            { "filename" : "\(file)", "idiom" : "tv", "scale" : "\(scale)x" }
        """)
    }
    try write(json: """
    {
      "images" : [
    \(images.joined(separator: ",\n"))
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """, "\(brand)/\(name).imageset/Contents.json")
}

try topShelf("Top Shelf Image", width: 1920, height: 720)
try topShelf("Top Shelf Image Wide", width: 2320, height: 720)

print("the stone")
try writeGem()

print("done")


// MARK: - The stone

/// The disc the app's cabochons are filled with, cut from the same stone the
/// icons are grounded on, so the gem under the thumb and the icon on the home
/// screen are one object. `StainedGlass` fills a circle with this as an
/// `ImagePaint`, so what it wants is a square whose content is the disc.
func writeGem(side: Int = 512, cut: Cut = gemCut) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("no bitmap at \(side)")
    }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let box = NSRect(x: 0, y: 0, width: side, height: side)
    NSBezierPath(ovalIn: box).addClip()
    fill(box, from: cut)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    try write(png, "Apps/Topo/Assets.xcassets/agate.imageset/agate.png")
}

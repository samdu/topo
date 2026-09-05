#!/usr/bin/env swift
// Renders the app icons from Design/topo-mark.svg.
//
//   swift Design/make-icons.swift        # from the repository root
//
// The SVG is the source: this reads its paths rather than holding a second
// copy of the mark, so a change to the drawing is a change in one place.
// Everything it writes is committed, so nobody needs Xcode to run this to
// build the app — only to change the mark.
//
// The ground is the identity's icon gradient, #0A8EA1 to #005C6B at 160°,
// and the mark is white on it. iOS and watchOS icons are full-bleed squares
// (the system masks them), macOS draws its own rounded square with the
// margin that platform expects, and tvOS is a layered stack: ground behind,
// mark in front, so it parallaxes under the remote.

import AppKit
import Foundation

// MARK: - The mark

/// One `d` attribute: a move, then cubic segments. The mark uses no other
/// commands, so this reads what is there rather than all of SVG.
func path(fromD d: String) -> CGPath {
    let numbers = d.split(whereSeparator: { " ,MC".contains($0) }).compactMap { Double($0) }
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
    return path
}

func matches(_ pattern: String, in text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range(at: 1), in: text)!])
    }
}

/// The mark as one filled path in its own 100×100 space, arms stroked and
/// head filled, ready to be scaled into whatever canvas is asked for.
func mark(fromSVG svg: String) -> CGPath {
    let strokeWidth = Double(matches("stroke-width=\"([0-9.]+)\"", in: svg).first ?? "6") ?? 6
    let whole = CGMutablePath()
    for d in matches("<path d=\"([^\"]+)\"", in: svg) {
        let stroked = path(fromD: d).copy(strokingWithWidth: strokeWidth, lineCap: .round,
                                          lineJoin: .round, miterLimit: 10)
        whole.addPath(stroked)
    }
    let circle = matches("<circle cx=\"([0-9.]+)\" cy=\"[0-9.]+\" r=\"[0-9.]+\"", in: svg)
    guard !circle.isEmpty,
          let cx = Double(matches("cx=\"([0-9.]+)\"", in: svg).first ?? ""),
          let cy = Double(matches("cy=\"([0-9.]+)\"", in: svg).first ?? ""),
          let r = Double(matches(" r=\"([0-9.]+)\"", in: svg).first ?? "") else {
        fatalError("Design/topo-mark.svg: no head")
    }
    whole.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    return whole
}

// MARK: - Drawing

let groundTop = NSColor(srgbRed: 0x0A / 255, green: 0x8E / 255, blue: 0xA1 / 255, alpha: 1)
let groundBottom = NSColor(srgbRed: 0x00 / 255, green: 0x5C / 255, blue: 0x6B / 255, alpha: 1)
/// 160° in CSS is mostly downwards and a little to the right; NSGradient
/// measures the other way round, from the x axis with y upwards.
let groundAngle: CGFloat = -70

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

    let gradient = NSGradient(starting: groundTop, ending: groundBottom)!
    switch ground {
    case .full:
        gradient.draw(in: NSRect(origin: .zero, size: size), angle: groundAngle)
    case .rounded(let margin):
        let inset = min(size.width, size.height) * margin
        let box = NSRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
        let radius = box.width * 0.225
        gradient.draw(in: NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius), angle: groundAngle)
    case .none:
        break
    }

    // The mark, white, centred on its own ink rather than on its 100×100
    // box, and flipped: SVG counts y downwards and Quartz counts it up.
    let ink = markPath.boundingBoxOfPath
    let scale = markHeight / max(ink.width, ink.height)
    let place = CGAffineTransform.identity
        .translatedBy(x: (size.width - ink.width * scale) / 2 - ink.minX * scale,
                      y: (size.height - ink.height * scale) / 2 - ink.minY * scale)
        .scaledBy(x: scale, y: scale)
    let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
    let placed = CGMutablePath()
    placed.addPath(markPath, transform: place.concatenating(flip))
    cg.setFillColor(NSColor.white.cgColor)
    cg.addPath(placed)
    cg.fillPath()

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

print("done")

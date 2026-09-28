import SwiftUI
import UIKit
import TopoCore
import XCTest

@testable import Topo

/// Review Focus 2: what `WidgetNodeView` draws for each family, against a committed reference.
///
/// Each family's fixture (`Tests/Client/Widgets/<family>.json`) holds every node kind that family
/// takes. It is drawn through `ImageRenderer` at the family's size in light and in dark and
/// compared pixel by pixel with `References/<family>-<appearance>.png`, a pixel counting as
/// changed when a channel moves by more than `channelTolerance` and a picture as another one when
/// more than `changedTolerance` of its pixels have. A node drawn empty, clipped or in the wrong
/// colour is another picture; and each comparison is shown able to fail for the defect it claims,
/// since the fixture with any one node taken out is another picture too.
///
/// `TEST_RUNNER_TOPO_RECORD_WIDGETS=1` writes the references afresh (into the source tree) and
/// fails, so a recording is never a pass.
@MainActor
final class WidgetSnapshotTests: XCTestCase {
    static let families: [(WidgetFamilyName, CGSize)] = [
        (.systemSmall, CGSize(width: 170, height: 170)),
        (.systemMedium, CGSize(width: 364, height: 170)),
        (.systemLarge, CGSize(width: 364, height: 382)),
        (.accessoryCircular, CGSize(width: 76, height: 76)),
        (.accessoryRectangular, CGSize(width: 172, height: 76)),
        (.accessoryInline, CGSize(width: 257, height: 26)),
    ]
    static let channelTolerance = 24
    static let changedTolerance = 0.0005
    static let scale: CGFloat = 2

    private var recording: Bool { ProcessInfo.processInfo.environment["TOPO_RECORD_WIDGETS"] == "1" }

    static func fixture(_ family: WidgetFamilyName) throws -> WidgetDocument {
        let url = try XCTUnwrap(Bundle(for: WidgetSnapshotTests.self).url(forResource: family.rawValue, withExtension: "json"),
                                "no fixture for \(family.rawValue)")
        let reading = WidgetDocument.read(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(reading.notes, [], "the \(family.rawValue) fixture is not read whole")
        return reading.document
    }

    /// A picture for the fixtures' image nodes: four blocks of colour, the same every time.
    static let photo: Data = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).pngData { context in
        for (index, colour) in [UIColor.systemRed, .systemBlue, .systemGreen, .systemOrange].enumerated() {
            colour.setFill()
            context.fill(CGRect(x: (index % 2) * 20, y: (index / 2) * 20, width: 20, height: 20))
        }
    }

    static func render(_ node: WidgetNode, family: WidgetFamilyName, size: CGSize, dark: Bool,
                       privateText: Bool = false) throws -> CGImage {
        let context = WidgetContext(slot: "fixture", revision: 1, family: family, images: ["photo": photo], privateText: privateText)
        let view = WidgetNodeView(node: node, context: context)
            .padding(family.isAccessory ? 0 : 16)
            .frame(width: size.width, height: size.height)
            .background(Theme.surface)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return try XCTUnwrap(renderer.cgImage, "\(family.rawValue) rendered to nothing")
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// The share of pixels that changed between two pictures of one size.
    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var count = 0
        for pixel in stride(from: 0, to: a.count, by: 4) {
            for channel in 0..<4 where abs(Int(a[pixel + channel]) - Int(b[pixel + channel])) > channelTolerance {
                count += 1
                break
            }
        }
        return Double(count) / Double(a.count / 4)
    }

    private func referenceURL(_ name: String) -> URL? {
        Bundle(for: WidgetSnapshotTests.self).url(forResource: name, withExtension: "png")
    }

    private func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Widgets/References/\(name).png")
    }

    private func reference(_ name: String, _ image: CGImage) throws -> [UInt8]? {
        if recording {
            let data = try XCTUnwrap(UIImage(cgImage: image).pngData())
            try data.write(to: sourceURL(name))
            XCTFail("recorded \(name); run again without TOPO_RECORD_WIDGETS")
            return nil
        }
        let url = try XCTUnwrap(referenceURL(name), "no reference \(name).png; record with TEST_RUNNER_TOPO_RECORD_WIDGETS=1")
        let stored = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage, "\(name).png is not a picture")
        XCTAssertEqual(stored.width, image.width, "\(name): the reference is another size")
        XCTAssertEqual(stored.height, image.height, "\(name): the reference is another size")
        return Self.pixels(stored)
    }

    /// Every node below the root, as the child indexes that reach it.
    static func paths(_ node: WidgetNode, _ prefix: [Int] = []) -> [[Int]] {
        guard case .stack(let stack) = node else { return [] }
        return stack.children.enumerated().flatMap { index, child in [prefix + [index]] + paths(child, prefix + [index]) }
    }

    static func removing(_ path: [Int], from node: WidgetNode) -> WidgetNode {
        guard case .stack(var stack) = node, let first = path.first else { return node }
        if path.count == 1 { stack.children.remove(at: first) }
        else { stack.children[first] = removing(Array(path.dropFirst()), from: stack.children[first]) }
        return .stack(stack)
    }

    func testEachFamilyDrawsItsReference() throws {
        for (family, size) in Self.families {
            let tree = try XCTUnwrap(Self.fixture(family).tree(for: family))
            for dark in [false, true] {
                let name = "\(family.rawValue)-\(dark ? "dark" : "light")"
                let drawn = try Self.render(tree, family: family, size: size, dark: dark)
                guard let expected = try reference(name, drawn) else { continue }
                let changed = Self.changed(Self.pixels(drawn), expected)
                XCTAssertLessThanOrEqual(changed, Self.changedTolerance, "\(name) drew another picture: \(Int(changed * 1000))‰ of it changed")
            }
        }
    }

    /// The fixtures hold every kind their family takes: all of them on the home screen.
    func testTheHomeScreenFixturesHoldEveryKind() throws {
        let every: Set<String> = ["vstack", "hstack", "zstack", "text", "glyph", "image", "gauge", "progress", "topo",
                                  "spacer", "divider", "button", "toggle", "link"]
        for family in [WidgetFamilyName.systemSmall, .systemMedium, .systemLarge] {
            var kinds: Set<String> = []
            try XCTUnwrap(Self.fixture(family).tree(for: family)).walk { kinds.insert($0.kind) }
            XCTAssertEqual(kinds.intersection(every), every, "\(family.rawValue) lacks \(every.subtracting(kinds))")
        }
    }

    // MARK: The default (Review Focus 7)

    private static func reply(_ text: String) -> Turn {
        Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 2), parents: [], role: .assistant, text: text,
             at: Date(timeIntervalSince1970: 1_900_000_000))
    }

    /// The default written for a reply whose every word is a sentinel holds none of it on a
    /// lock-screen family: no field of the entry the provider makes for one carries the reply's
    /// text, and the picture it draws is the one it draws for a different reply at the same time.
    /// The home-screen families carry the first sentence, marked private.
    func testDefaultLockFamiliesHoldNoReply() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("default-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SurfaceStore(folder: folder)
        let sentinel = "Zebracorn"
        let secret = Self.reply("\(sentinel) ate the \(sentinel) pie. \(sentinel) again.")
        let other = Self.reply("Nothing to see here. At all.")

        var pictures: [WidgetFamilyName: [UInt8]] = [:]
        for (reply, pass) in [(secret, 0), (other, 1)] {
            try store.writeDefault(DefaultSurface.document(reply))
            for (family, size) in Self.families {
                guard case .drawn(let node, let context, _, _) = SurfaceProvider.surface(slot: nil, family: family, at: Date(), store: store) else {
                    return XCTFail("\(family.rawValue): the default was not drawn")
                }
                if family.isAccessory {
                    XCTAssertFalse(String(describing: node).contains(sentinel), "\(family.rawValue) carries the reply")
                    XCTAssertFalse(String(describing: context).contains(sentinel), "\(family.rawValue)'s context carries the reply")
                    let drawn = Self.pixels(try Self.render(node, family: family, size: size, dark: false, privateText: context.privateText))
                    if pass == 0 { pictures[family] = drawn }
                    else { XCTAssertEqual(Self.changed(drawn, pictures[family] ?? []), 0, "\(family.rawValue) draws the reply") }
                } else if pass == 0 {
                    XCTAssertTrue(context.privateText, "\(family.rawValue): the reply is not marked private")
                    var words: [String] = []
                    node.walk { if case .text(let text) = $0 { words.append(text.text) } }
                    XCTAssertTrue(words.contains("\(sentinel) ate the \(sentinel) pie."), "\(family.rawValue) lacks the first sentence: \(words)")
                    XCTAssertFalse(words.contains { $0.contains("again") }, "\(family.rawValue) carries more than the first sentence")
                }
            }
        }
    }

    /// The default reads whole, with and without a reply, and is never a signed-out entry.
    func testTheDefaultReadsWhole() throws {
        for reply in [nil, Self.reply("Out tonight. The bins.")] {
            let document = DefaultSurface.document(reply)
            let reading = WidgetDocument.read(document.text, from: .store)
            XCTAssertEqual(reading.notes, [])
            for (family, _) in Self.families { XCTAssertNotNil(document.tree(for: family), family.rawValue) }
        }
    }

    /// The comparison can fail for what it claims: with any one node taken out, the fixture is
    /// another picture than its reference.
    func testANodeTakenOutIsAnotherPicture() throws {
        guard !recording else { return }
        for (family, size) in Self.families {
            let tree = try XCTUnwrap(Self.fixture(family).tree(for: family))
            let name = "\(family.rawValue)-light"
            guard let url = referenceURL(name), let stored = UIImage(contentsOfFile: url.path)?.cgImage else {
                XCTFail("no reference \(name)"); continue
            }
            let expected = Self.pixels(stored)
            for path in Self.paths(tree) {
                let without = Self.removing(path, from: tree)
                let drawn = try Self.render(without, family: family, size: size, dark: false)
                let changed = Self.changed(Self.pixels(drawn), expected)
                XCTAssertGreaterThan(changed, Self.changedTolerance,
                                     "\(family.rawValue) without the node at \(path) is still its reference")
            }
        }
    }
}

/// When the default is written: for the newest reply the log brings, once each.
@MainActor
final class DefaultSurfaceTests: XCTestCase {
    private func turn(_ sequence: Int64, _ role: TurnRole, _ text: String) -> Turn {
        Turn(ref: TurnRef(device: DeviceID("phone"), sequence: sequence), parents: [], role: role, text: text, at: Date())
    }

    func testTheDefaultFollowsTheNewestReplyOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("default-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SurfaceStore(folder: folder)
        var reloads = 0
        let surface = DefaultSurface(store: { store },
                                     reloader: SurfaceReloader(reloadKind: { _ in reloads += 1 }, reloadEverything: {},
                                                               schedule: { _, body in body() }))
        let turns = [turn(1, .person, "Bins?"), turn(2, .assistant, "Tonight. Out front."),
                     turn(3, .person, "Thanks"), turn(4, .assistant, "Any time.")]
        surface.launched(latest: nil)
        XCTAssertNotNil(store.read(slot: SurfaceStore.defaultSlot), "signed in with no reply yet draws nothing")
        // A read brings every reply in order; only the newest is the default.
        for reply in turns where reply.role == .assistant { surface.landed(reply, in: turns) }
        surface.landed(turns[3], in: turns)
        var words: [String] = []
        store.read(slot: SurfaceStore.defaultSlot)?.document.tree(for: .systemMedium)?.walk {
            if case .text(let text) = $0 { words.append(text.text) }
        }
        XCTAssertTrue(words.contains("Any time."), "\(words)")
        XCTAssertFalse(words.contains("Tonight."), "\(words)")
        XCTAssertEqual(reloads, 2, "one write on launch and one for the newest reply")
    }

    /// Signed out and in again: the sign-out took the default with it, and the sign-in writes it
    /// afresh rather than leaving every widget saying "Sign in on your phone".
    func testSigningBackInWritesTheDefaultAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("default-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SurfaceStore(folder: folder)
        let reloader = SurfaceReloader(reloadKind: { _ in }, reloadEverything: {}, schedule: { _, _ in })
        let surface = DefaultSurface(store: { store }, reloader: reloader)
        surface.launched(latest: nil)
        reloader.forget(store)
        surface.forget()
        XCTAssertNil(store.read(slot: SurfaceStore.defaultSlot))
        surface.launched(latest: nil)
        XCTAssertNotNil(store.read(slot: SurfaceStore.defaultSlot), "signed back in, and the widgets still say to sign in")
    }
}

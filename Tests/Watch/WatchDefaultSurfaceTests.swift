import TopoCore
import XCTest

@testable import TopoWatch

/// Review Focus 7: the watch's default carries no word of a reply on any family, `accessoryCorner`
/// included, since a watch face is read by whoever sees the wrist.
@MainActor
final class WatchDefaultSurfaceTests: XCTestCase {
    private static func reply(_ text: String) -> Turn {
        Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 2), parents: [], role: .assistant, text: text,
             at: Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testDefaultFamiliesHoldNoReply() throws {
        let sentinel = "Zebracorn"
        let document = WatchDefaultSurface.document(Self.reply("\(sentinel) ate the \(sentinel) pie."))
        for family in [WidgetFamilyName.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner] {
            let tree = try XCTUnwrap(document.tree(for: family), "\(family.rawValue) draws nothing")
            XCTAssertFalse(String(describing: tree).contains(sentinel), "\(family.rawValue) carries the reply")
        }
        XCTAssertNotNil(document.families[.accessoryCorner])
        XCTAssertFalse(document.text.contains(sentinel), "the document carries the reply")
        XCTAssertEqual(document, WatchDefaultSurface.document(Self.reply("Nothing to see here.")),
                       "two replies at one time made two defaults")
    }

    func testTheDefaultFollowsTheNewestReplyOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("default-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SurfaceStore(folder: folder)
        var reloads = 0
        let standing = WatchDefaultSurface(store: { store }, changed: { reloads += 1 })
        let reply = Self.reply("Hello.")
        standing.follow([reply])
        standing.follow([reply])
        XCTAssertEqual(reloads, 1)
        XCTAssertNotNil(store.read(slot: SurfaceStore.defaultSlot))
    }
}

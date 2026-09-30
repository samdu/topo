import XCTest

@testable import TopoWatch

/// `TopoMoment`: a slot that names a context is offered for it, and the card drawn for it is the
/// slot's own `accessoryRectangular` tree.
@available(watchOS 26, *)
final class TopoMomentTests: XCTestCase {
    private var folder: URL!
    private var store: SurfaceStore!

    static let bedtime = #"""
    {"version": 1, "relevant": [{"sleep": "bedtime"}],
     "families": {"default": {"kind": "text", "text": "night"},
                  "accessoryRectangular": {"kind": "text", "text": "lights out"}}}
    """#

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("moment-\(UUID().uuidString)")
        store = SurfaceStore(folder: folder)
        var document = WidgetDocument.read(Self.bedtime).document
        document.revision = 7
        try store.keep(document, slot: "night")
        var plain = WidgetDocument.read(#"{"version": 1, "families": {"default": {"kind": "text", "text": "day"}}}"#).document
        plain.revision = 2
        try store.keep(plain, slot: "day")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testABedtimeSlotIsOfferedAndDrawn() throws {
        let offered = MomentProvider.offered(store: store)
        XCTAssertEqual(offered.map(\.slot), ["night"], "a slot naming no context was offered, or one naming one was not")
        XCTAssertEqual(offered.map(\.context), [.sleep(.bedtime)])

        let entry = MomentProvider.entry(slot: "night", store: store, at: Date())
        guard case .drawn(let node, let context, _, _) = entry.surface else { return XCTFail("\(entry.surface)") }
        XCTAssertEqual(context.slot, "night")
        XCTAssertEqual(context.revision, 7)
        XCTAssertEqual(context.family, .accessoryRectangular)
        XCTAssertEqual(node, store.read(slot: "night")?.document.tree(for: .accessoryRectangular))
        guard case .text(let text) = node else { return XCTFail("\(node)") }
        XCTAssertEqual(text.text, "lights out")
    }
}

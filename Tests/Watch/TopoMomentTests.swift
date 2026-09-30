import WidgetKit
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

    /// Through the provider's own `relevance()` and `entry(configuration:context:)`, the two the
    /// Smart Stack calls.
    func testABedtimeSlotIsOfferedAndDrawn() async throws {
        let provider = MomentProvider(store: { self.store })
        let offered = try Self.offered(await provider.relevance())
        XCTAssertEqual(offered.map(\.slot), ["night"], "a slot naming no context was offered, or one naming one was not")
        XCTAssertTrue(offered.allSatisfy { $0.context.contains(".sleep(.bedtime)") }, "\(offered)")

        let entry = try await provider.entry(configuration: SurfaceConfiguration(slot: "night"), context: Self.context())
        guard case .drawn(let node, let context, _, _) = entry.surface else { return XCTFail("\(entry.surface)") }
        XCTAssertEqual(context.slot, "night")
        XCTAssertEqual(context.revision, 7)
        XCTAssertEqual(context.family, .accessoryRectangular)
        XCTAssertEqual(node, store.read(slot: "night")?.document.tree(for: .accessoryRectangular))
        guard case .text(let text) = node else { return XCTFail("\(node)") }
        XCTAssertEqual(text.text, "lights out")
    }

    /// What a `WidgetRelevance` holds, read by reflection since it has no API to read: each
    /// entry's slot and a description of its context. A layout this does not find fails the test
    /// rather than passing it empty.
    private static func offered(_ relevance: WidgetRelevance<SurfaceConfiguration>) throws -> [(slot: String?, context: String)] {
        let storage = try XCTUnwrap(Mirror(reflecting: relevance).descendant("relevances", "storage"), "WidgetRelevance's layout moved")
        let entries = try XCTUnwrap(Mirror(reflecting: storage).children.first?.value, "WidgetRelevance's layout moved")
        return try Mirror(reflecting: entries).children.map { entry in
            let configuration = try XCTUnwrap(Mirror(reflecting: entry.value).descendant("configuration") as? SurfaceConfiguration)
            let attribute = try XCTUnwrap(Mirror(reflecting: entry.value).descendant("attribute"))
            var context = ""
            dump(attribute, to: &context)
            return (configuration.slot, context)
        }
    }

    /// The provider's context, which WidgetKit makes and nothing else can: a display size and a
    /// preview flag, zeroed. The entry does not read it; the size check fails the test if its
    /// layout is ever other than those two.
    private static func context() throws -> RelevanceEntriesProviderContext {
        typealias Context = RelevanceEntriesProviderContext
        struct LayoutMoved: Error {}
        guard MemoryLayout<Context>.size == MemoryLayout<CGSize>.size + MemoryLayout<Bool>.size else { throw LayoutMoved() }
        return withUnsafeTemporaryAllocation(byteCount: MemoryLayout<Context>.size, alignment: MemoryLayout<Context>.alignment) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            return bytes.baseAddress!.load(as: Context.self)
        }
    }
}

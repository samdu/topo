import Foundation
import TopoTools
import XCTest
import TopoUserland

@testable import Topo

/// A picker that answers what the test gives it, with a file of the test's making.
private final class Picker: FilePicker, @unchecked Sendable {
    private let answer: @Sendable () async -> FilePick
    private let _picks = LockedBox(0)
    init(_ answer: @escaping @Sendable () async -> FilePick) { self.answer = answer }
    var picks: Int { _picks.with { $0 } }
    func pick() async -> FilePick {
        _picks.with { $0 += 1 }
        return await answer()
    }
}

private final class Drop: VaultDrop, @unchecked Sendable {
    struct Dropped: Equatable {
        var data: Data
        var name: String
        var folder: String
    }

    let dropped = LockedBox<[Dropped]>([])
    let deadlines = LockedBox<[Date]>([])
    var outcome = VaultDropOutcome.placed
    func drop(_ data: Data, named name: String, into folder: String, by deadline: Date) async throws -> VaultDropOutcome {
        deadlines.with { $0.append(deadline) }
        dropped.with { $0.append(Dropped(data: data, name: name, folder: folder)) }
        return outcome
    }
}

final class FilesToolTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("files-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The picker's copy of a file the person chose.
    private func picked(_ name: String, _ data: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static let pdf = Data([0x25, 0x50, 0x44, 0x46, 0xff, 0xfe, 0x00, 0x80])

    func testAPickedFileLandsInTheInboxAndItsCopyIsRemoved() async throws {
        let url = try picked("report.pdf", Self.pdf)
        let drop = Drop()
        let reply = await FilesTool(picker: Picker { .picked(url) }, drop: drop).run(["pick"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertTrue(reply.text.hasPrefix("picked: /home/topo/memory/inbox/report.pdf (8 bytes)\n"), reply.text)
        XCTAssertTrue(reply.text.contains("not text"), "a file the mirror does not carry is not said to be one: \(reply.text)")
        XCTAssertEqual(drop.dropped.with { $0 }, [.init(data: Self.pdf, name: "report.pdf", folder: "inbox")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the picker's copy was left behind")
    }

    func testATextFileGoesWhereIntoSaysAndIsSaidPlainly() async throws {
        let url = try picked("notes.md", Data("# Notes\n".utf8))
        let drop = Drop()
        let reply = await FilesTool(picker: Picker { .picked(url) }, drop: drop).run(["pick", "--into", "papers/2026/"])
        XCTAssertEqual(reply, .ok("picked: /home/topo/memory/papers/2026/notes.md (8 bytes)\n"))
        XCTAssertEqual(drop.dropped.with { $0 }.first?.folder, "papers/2026")
    }

    /// The mirror carries a text file to the store whole, so one over a note's size is refused
    /// rather than left in the folder for every sync to fail on; a file over the cap is too.
    func testATextFileOverANotesSizeAndAnyFileOverTheCapAreRefused() async throws {
        let drop = Drop()
        let text = try picked("log.csv", Data(repeating: UInt8(ascii: "a"), count: FilesTool.textBytes + 1))
        let long = await FilesTool(picker: Picker { .picked(text) }, drop: drop).run(["pick"])
        XCTAssertEqual(long.status, ToolReply.refused, long.text)
        XCTAssertTrue(long.text.contains("of text"), long.text)

        let fits = try picked("fits.csv", Data(repeating: UInt8(ascii: "a"), count: FilesTool.textBytes))
        let kept = await FilesTool(picker: Picker { .picked(fits) }, drop: drop).run(["pick"])
        XCTAssertEqual(kept.status, ToolReply.ok, kept.text)

        var bytes = Data(repeating: 0xff, count: FilesTool.bytes + 1)
        bytes[0] = 0x00
        let big = try picked("film.mov", bytes)
        let over = await FilesTool(picker: Picker { .picked(big) }, drop: drop).run(["pick"])
        XCTAssertEqual(over.status, ToolReply.refused, over.text)
        XCTAssertEqual(drop.dropped.with { $0 }.map(\.name), ["fits.csv"])
        for url in [text, big] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a refused pick's copy was left behind")
        }
    }

    func testNoFileIsAFailureThatSaysWhyAndNothingIsDropped() async {
        let drop = Drop()
        for (pick, said) in [(FilePick.cancelled, "closed the picker"), (.unanswered, "within a minute"),
                             (.unavailable("the Topo app is not on the screen"), "not on the screen")] {
            let reply = await FilesTool(picker: Picker { pick }, drop: drop).run(["pick"])
            XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
            XCTAssertTrue(reply.text.contains(said), reply.text)
        }
        XCTAssertTrue(drop.dropped.with { $0 }.isEmpty)
    }

    func testANameAlreadyThereAndAMemoryNotMountedWriteNothingAndSaySo() async throws {
        let drop = Drop()
        drop.outcome = .exists
        let first = try picked("a.pdf", Self.pdf)
        let exists = await FilesTool(picker: Picker { .picked(first) }, drop: drop).run(["pick"])
        XCTAssertEqual(exists.status, ToolReply.refused, exists.text)
        XCTAssertTrue(exists.text.contains("/home/topo/memory/inbox/a.pdf is already there"), exists.text)
        drop.outcome = .unmounted
        let second = try picked("b.pdf", Self.pdf)
        let unmounted = await FilesTool(picker: Picker { .picked(second) }, drop: drop).run(["pick"])
        XCTAssertEqual(unmounted.status, ToolReply.failed, unmounted.text)
        XCTAssertTrue(unmounted.text.contains("nothing was kept"), unmounted.text)
    }

    /// A call that is not `pick`, or names a folder that is not one in the memory, puts no picker up.
    func testAMisusePutsNoPickerUp() async {
        let picker = Picker { .cancelled }
        let tool = FilesTool(picker: picker, drop: Drop())
        for call in [[], ["list"], ["pick", "extra"], ["pick", "--into", "/etc"], ["pick", "--into", "../up"], ["pick", "--into", "a/./b"],
                     ["pick", "--into", ".topo"], ["pick", "--into", "notes/.hidden"], ["pick", "--into", "a\nb"], ["pick", "--into"],
                     ["pick", "--name", "x"], ["pick", "--into", ""]] {
            let reply = await tool.run(call)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(call): \(reply.text)")
            XCTAssertTrue(reply.text.contains("topo files pick"), "\(call) is not answered with the usage")
        }
        XCTAssertEqual(picker.picks, 0)
    }

    /// A call cancelled while the picker was up — the service's bound — puts nothing in the memory.
    func testACallCancelledWhileThePersonChoosesDropsNothing() async throws {
        let url = try picked("late.pdf", Self.pdf)
        let drop = Drop()
        let up = expectation(description: "the picker is up")
        let release = LockedBox<CheckedContinuation<Void, Never>?>(nil)
        let tool = FilesTool(picker: Picker {
            await withCheckedContinuation { continuation in
                release.with { $0 = continuation }
                up.fulfill()
            }
            return .picked(url)
        }, drop: drop)
        let call = Task { await tool.run(["pick"]) }
        await fulfillment(of: [up], timeout: 5)
        call.cancel()
        release.with { $0 }?.resume()
        let reply = await call.value
        XCTAssertEqual(reply.status, ToolReply.timedOut)
        XCTAssertTrue(drop.dropped.with { $0 }.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAPickedNameIsMadeOneTheMemoryCanHold() {
        XCTAssertEqual(FilesTool.fileName("report.pdf"), "report.pdf")
        XCTAssertEqual(FilesTool.fileName(".hidden"), "hidden")
        XCTAssertEqual(FilesTool.fileName("..  .topo"), "topo")
        XCTAssertEqual(FilesTool.fileName("a/b\nc\u{2028}d.txt"), "abcd.txt")
        XCTAssertEqual(FilesTool.fileName("..."), "file")
        XCTAssertEqual(FilesTool.fileName(""), "file")
        let long = FilesTool.fileName(String(repeating: "x", count: 400) + ".pdf")
        XCTAssertEqual(long, String(repeating: "x", count: 196) + ".pdf")
        // A name is cut by its bytes, which is what a filesystem counts, and keeps one ending.
        let wide = FilesTool.fileName(String(repeating: "字", count: 70) + ".pdf")
        XCTAssertEqual(wide, String(repeating: "字", count: 65) + ".pdf")
        XCTAssertLessThanOrEqual(FilesTool.fileName(String(repeating: "👨‍👩‍👧", count: 120)).utf8.count, FilesTool.nameBytes)
        XCTAssertEqual(FilesTool.folder("notes//papers/"), "notes/papers")
        XCTAssertNil(FilesTool.folder("/notes"))
        XCTAssertNil(FilesTool.folder(".."))
    }

    /// A pick is given its name in the memory only while one wait of the vault's still ends inside
    /// the tool service's bound, and one that is too late for that is said to be, with nothing kept.
    func testAPickIsPlacedOnlyInsideTheServicesBound() async throws {
        let file = scratch.appendingPathComponent("late.bin")
        try Data([0xff, 0xfe, 0x00]).write(to: file)
        let drop = Drop()
        drop.outcome = .late
        let began = Date()
        let reply = await FilesTool(picker: Picker { .picked(file) }, drop: drop).run(["pick"])
        XCTAssertEqual(reply.status, ToolReply.failed)
        XCTAssertTrue(reply.text.contains("too late in the call"), reply.text)
        let deadline = try XCTUnwrap(drop.deadlines.with { $0.first })
        XCTAssertLessThanOrEqual(deadline.timeIntervalSince(began) + Double(Guest.vaultWait / .seconds(1)), 90 - 4,
                                 "a placement that waits its whole bound would end after the service answered")
        XCTAssertGreaterThan(deadline.timeIntervalSince(began), Double(DocumentPicker.bound / .seconds(1)))
    }
}

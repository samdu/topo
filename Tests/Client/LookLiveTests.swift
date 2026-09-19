import CloudKit
import SwiftUI
import TopoCore
import TopoCoreTesting
import XCTest

@testable import Topo

/// `look.json` as the memory reads it: a file of the vault like any other, read after each sync
/// through the mirror's own coordination, from whichever folder the home names. Everything here
/// runs over the in-memory database and a directory of its own; nothing touches iCloud.
@MainActor
final class LookLiveTests: XCTestCase {
    private let phone = DeviceID("phone")
    private let hub = DeviceID("hub")
    private let path = VaultPath(LookDocument.name)!
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("topo-look-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.appendingPathComponent("Vault", isDirectory: true)
    }

    private func memory(_ database: any RecordDatabase, at directory: URL,
                        signedIn: @escaping @Sendable () -> Bool = { true }) -> Memory {
        Memory(directory: directory, store: MemoryStore(database: database), device: phone,
               isSignedIn: signedIn, ensureZone: {})
    }

    /// Written the way the mind writes it: a revision of a note in the vault, made on another
    /// device, which the sync brings to the folder.
    @discardableResult
    private func write(_ text: String, to path: VaultPath, in database: any RecordDatabase,
                       at when: Date? = nil) async throws -> Int {
        let store = MemoryStore(database: database)
        let writer = try await store.writer(for: hub)
        try await writer.write(text, to: path, continuing: store.read(), at: when ?? t0)
        return 0
    }

    private func remove(_ path: VaultPath, in database: any RecordDatabase, at when: Date) async throws {
        let store = MemoryStore(database: database)
        let writer = try await store.writer(for: hub)
        try await writer.delete(path, continuing: store.read(), at: when)
    }

    // MARK: A vault with no document in it

    func testAVaultWithNoDocumentIsTheCompiledLook() async throws {
        let database = InMemoryRecordDatabase()
        let memory = memory(database, at: makeDirectory())
        try await write("eggs", to: VaultPath("Groceries.md")!, in: database)

        await memory.sync()

        XCTAssertEqual(memory.look, Look())
        XCTAssertEqual(memory.lookReading.state, .absent)
        XCTAssertTrue(memory.lookReading.summary.contains("the compiled look"), memory.lookReading.summary)
    }

    // MARK: A document the mind wrote

    /// The whole path: the mind writes a revision of `look.json`, the sync brings it to the
    /// folder, and the app is wearing it when the pass returns.
    func testADocumentInTheVaultIsWornAfterTheNextSync() async throws {
        let database = InMemoryRecordDatabase()
        let directory = makeDirectory()
        let memory = memory(database, at: directory)
        try await write(LookFixture.full, to: path, in: database)

        await memory.sync()

        XCTAssertEqual(memory.lookReading.notes, [])
        XCTAssertEqual(memory.lookReading.state, .read(fields: LookFixture.fields))
        XCTAssertEqual(memory.look.bubble.cornerRadius, 3)
        XCTAssertEqual(memory.look.composer.surface, .flat)
        XCTAssertEqual(memory.look.transcript.spacing, 20)
        // And it really is a file in the person's folder, where Files and an editor can reach it.
        XCTAssertNotNil(try? Data(contentsOf: directory.appendingPathComponent(LookDocument.name)))
    }

    /// Applied live: a document changed after one sync is worn from the next one, with no
    /// relaunch and nothing else touched.
    func testADocumentChangedAfterASyncIsWornFromTheNextOne() async throws {
        let database = InMemoryRecordDatabase()
        let memory = memory(database, at: makeDirectory())
        try await write(#"{"bubble": {"cornerRadius": 3}}"#, to: path, in: database)
        await memory.sync()
        XCTAssertEqual(memory.look.bubble.cornerRadius, 3)

        try await write(#"{"bubble": {"cornerRadius": 27}}"#, to: path, in: database,
                        at: t0.addingTimeInterval(60))
        await memory.sync()

        XCTAssertEqual(memory.look.bubble.cornerRadius, 27)
        XCTAssertEqual(memory.lookReading.state, .read(fields: 1))
    }

    /// And the way back is deleting it: the document goes, the next sync takes the folder's copy
    /// with it, and the look is the compiled one again.
    func testADocumentDeletedIsTheCompiledLookAgain() async throws {
        let database = InMemoryRecordDatabase()
        let directory = makeDirectory()
        let memory = memory(database, at: directory)
        try await write(#"{"bubble": {"cornerRadius": 3}}"#, to: path, in: database)
        await memory.sync()
        XCTAssertEqual(memory.look.bubble.cornerRadius, 3)

        try await remove(path, in: database, at: t0.addingTimeInterval(60))
        await memory.sync()

        XCTAssertNil(try? Data(contentsOf: directory.appendingPathComponent(LookDocument.name)))
        XCTAssertEqual(memory.look, Look())
        XCTAssertEqual(memory.lookReading.state, .absent)
    }

    // MARK: What the row says

    /// One field the document got wrong costs that field and says which; everything else it said
    /// still stands, and the row carries the reason to the diagnostics screen.
    func testOneBadFieldIsOnTheRowAndTheRestOfTheDocumentStands() async throws {
        let database = InMemoryRecordDatabase()
        let memory = memory(database, at: makeDirectory())
        try await write(#"{"bubble": {"cornerRadius": "wide", "strokeWidth": 5}}"#, to: path,
                        in: database)

        await memory.sync()

        XCTAssertEqual(memory.look.bubble.strokeWidth, 5)
        XCTAssertEqual(memory.look.bubble.cornerRadius, Look().bubble.cornerRadius)
        XCTAssertEqual(memory.lookReading.notes, ["bubble.cornerRadius is not a length in points"])
        XCTAssertTrue(memory.lookReading.summary.contains("bubble.cornerRadius"),
                      memory.lookReading.summary)
    }

    /// Something standing where the document goes that is not a document: a folder of the
    /// person's. It is read as what it is — nothing this can use — rather than as an absence or
    /// as an empty file, and the row says so.
    func testAFolderStandingWhereTheDocumentGoesIsTheCompiledLookAndSaysSo() async throws {
        let database = InMemoryRecordDatabase()
        let directory = makeDirectory()
        let memory = memory(database, at: directory)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(LookDocument.name, isDirectory: true),
            withIntermediateDirectories: true)

        await memory.sync()

        XCTAssertEqual(memory.look, Look())
        XCTAssertEqual(memory.lookReading.state, .unreadable("is a folder"))
        XCTAssertTrue(memory.lookReading.summary.contains("is a folder"), memory.lookReading.summary)
    }

    // MARK: Whichever home the folder is in

    /// The document is read from the folder the home names, not from the folder the app happens
    /// to own: a vault the person keeps in iCloud Drive holds its own `look.json`, and that is
    /// the one worn. The ubiquity root and the ubiquity answer are injected, since a simulator
    /// has no iCloud Drive; the folders are ordinary folders laid out as the phone's are.
    func testTheDocumentIsReadFromWhicheverFolderIsTheHome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("topo-look-home-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let ubiquity = root.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let picked = ubiquity.appendingPathComponent("iCloud~md~obsidian/Documents/Memory",
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let local = root.appendingPathComponent("Containers/Documents/Vault", isDirectory: true)

        let database = InMemoryRecordDatabase()
        let ubiquityPath = ubiquity.standardizedFileURL.path
        let memory = Memory(directory: local, store: MemoryStore(database: database), device: phone,
                            isSignedIn: { true }, bookmarks: InMemoryBookmarkStore(),
                            ubiquityRoot: ubiquity,
                            isUbiquitous: { $0.standardizedFileURL.path.hasPrefix(ubiquityPath) },
                            warm: { _ in VaultDownloads.Report() }, ensureZone: {}, now: { [t0] in t0 })
        try await write(#"{"bubble": {"cornerRadius": 3}}"#, to: path, in: database)
        await memory.sync()
        XCTAssertEqual(memory.look.bubble.cornerRadius, 3)

        let refusal = await memory.keepInICloudDrive(picked)
        XCTAssertNil(refusal)
        XCTAssertEqual(memory.home, .iCloudDrive(picked: picked, folder: picked))
        try await write(#"{"bubble": {"cornerRadius": 21}}"#, to: path, in: database,
                        at: t0.addingTimeInterval(60))
        await memory.sync()

        XCTAssertEqual(memory.look.bubble.cornerRadius, 21)
        // And the file it was read from is the one in the folder the person picked.
        XCTAssertNotNil(try? Data(contentsOf: picked.appendingPathComponent(LookDocument.name)))
        XCTAssertNil(try? Data(contentsOf: local.appendingPathComponent(LookDocument.name)))
    }

    // MARK: The login

    /// The look is the vault's, so it goes with the vault: a phone that signed out draws the
    /// compiled look and not the one the account it let go of was wearing.
    func testSigningOutTakesTheLookWithTheFolder() async throws {
        let database = InMemoryRecordDatabase()
        let memory = memory(database, at: makeDirectory())
        try await write(#"{"bubble": {"cornerRadius": 3}}"#, to: path, in: database)
        await memory.sync()
        XCTAssertEqual(memory.look.bubble.cornerRadius, 3)

        memory.forget()

        XCTAssertEqual(memory.look, Look())
        XCTAssertEqual(memory.lookReading.state, .absent)
    }

    /// A pass that ran against no login writes no look either: the folder it would have read is
    /// one it has just taken away.
    func testACueWithNoLoginLeavesTheCompiledLook() async throws {
        let database = InMemoryRecordDatabase()
        let memory = memory(database, at: makeDirectory(), signedIn: { false })
        try await write(LookFixture.full, to: path, in: database)

        await memory.sync()

        XCTAssertEqual(memory.look, Look())
        XCTAssertEqual(memory.lookReading.state, .absent)
    }
    // MARK: The join between what was read and what is drawn

    /// The one join between the document and the views: what the memory read is what the subtree
    /// under it draws with. Everything on both sides of this is covered by the suites above and
    /// by the render suites; this is the line between them.
    func testTheSubtreeDrawsWithTheLookTheMemoryRead() async throws {
        let database = InMemoryRecordDatabase()
        let memory = memory(database, at: makeDirectory())

        await memory.sync()
        var worn: Look?
        _ = try LookStage.image(LookProbe { worn = $0 }.wearing(memory), look: Look())
        XCTAssertEqual(try LookCensus.different(try XCTUnwrap(worn), Look()), [],
                       "a vault with no document did not draw with the compiled look")

        try await write(#"{"bubble": {"cornerRadius": 3}}"#, to: path, in: database)
        await memory.sync()
        worn = nil
        _ = try LookStage.image(LookProbe { worn = $0 }.wearing(memory), look: Look())
        XCTAssertEqual(try XCTUnwrap(worn).bubble.cornerRadius, 3,
                       "the look the memory read did not reach the subtree")
    }

}

/// A view that says what look it was handed, which is the only way to read one back out of the
/// environment.
private struct LookProbe: View {
    let report: (Look) -> Void
    @Environment(\.look) private var look

    var body: some View {
        Color.white.onAppear { report(look) }
    }
}

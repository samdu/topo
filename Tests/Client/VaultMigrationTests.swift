import CloudKit
import TopoCore
import TopoCoreTesting
import XCTest

@testable import Topo

/// Moving the vault's folder from one home to the other. Everything here runs over the in-memory
/// database and a temporary directory standing in for the device: a simulator has no iCloud Drive,
/// so the ubiquity root and the ubiquity answer are injected and the picked folder is an ordinary
/// folder laid out the way the phone's is. Each test asserts the surviving contents of both
/// folders and the baseline, not the order of the calls that got there.
@MainActor
final class VaultMigrationTests: XCTestCase {
    private let phone = DeviceID("phone")
    private let hub = DeviceID("hub")
    private let groceries = VaultPath("Groceries.md")!
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A temporary stand-in for the device: this app's container beside the ubiquity root, laid
    /// out as they are on the phone.
    private struct Device {
        var root: URL
        var local: URL
        var ubiquityRoot: URL
        var obsidianVault: URL
        var iCloudDriveRoot: URL
        var outside: URL
    }

    private func makeDevice() -> Device {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("topo-move-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let ubiquity = root.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let device = Device(
            root: root,
            local: root.appendingPathComponent("Containers/Data/Application/app/Documents/Vault",
                                               isDirectory: true),
            ubiquityRoot: ubiquity,
            obsidianVault: ubiquity.appendingPathComponent("iCloud~md~obsidian/Documents/Memory",
                                                           isDirectory: true),
            iCloudDriveRoot: ubiquity.appendingPathComponent("com~apple~CloudDocs", isDirectory: true),
            outside: root.appendingPathComponent("Containers/Shared/Elsewhere", isDirectory: true))
        for folder in [device.obsidianVault, device.iCloudDriveRoot, device.outside] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return device
    }

    private func memory(_ database: any RecordDatabase, on device: Device,
                        bookmarks: InMemoryBookmarkStore = InMemoryBookmarkStore()) -> Memory {
        let ubiquity = device.ubiquityRoot.standardizedFileURL.path
        return Memory(directory: device.local, store: MemoryStore(database: database), device: phone,
                      isSignedIn: { true }, bookmarks: bookmarks, ubiquityRoot: device.ubiquityRoot,
                      isUbiquitous: { $0.standardizedFileURL.path.hasPrefix(ubiquity) },
                      warm: { _ in VaultDownloads.Report() }, ensureZone: {}, now: { [t0] in t0 })
    }

    // MARK: Looking at folders

    private func text(_ relative: String, in root: URL) -> String? {
        let file = relative.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Everything the folder holds, hidden names included, deepest name first, as relative paths.
    /// Nil when the folder itself is not there.
    private func contents(of root: URL) -> [String]? {
        guard FileManager.default.fileExists(atPath: root.standardizedFileURL.path) else { return nil }
        let base = root.standardizedFileURL.path
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: []) else { return [] }
        var out: [String] = []
        for case let url as URL in walk {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            out.append(String(full.dropFirst(base.count + 1)))
        }
        return out.sorted()
    }

    private func write(_ text: String, to path: VaultPath, in database: any RecordDatabase,
                       as device: DeviceID, at when: Date) async throws {
        let store = MemoryStore(database: database)
        let writer = try await store.writer(for: device)
        try await writer.write(text, to: path, continuing: store.read(), at: when)
    }

    /// Waits for something the test can observe, failing rather than hanging when it never comes.
    private func eventually(_ what: String, within seconds: TimeInterval = 10,
                            _ condition: @MainActor () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !(try condition()) {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            await Task.yield()
        }
    }

    private func put(_ text: String, at relative: String, in root: URL) {
        let file = relative.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file)
    }

    // MARK: A move

    func testAMoveCarriesEveryFileAndTheBaselineAndEmptiesTheSource() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        try await write("# Today", to: VaultPath("notes/today.md")!, in: database, as: hub, at: t0)
        let memory = memory(database, on: device)
        await memory.sync()
        XCTAssertEqual(text("Groceries.md", in: device.local), "eggs")

        let refusal = await memory.keepInICloudDrive(device.obsidianVault)

        XCTAssertNil(refusal)
        XCTAssertEqual(text("Groceries.md", in: device.obsidianVault), "eggs")
        XCTAssertEqual(text("notes/today.md", in: device.obsidianVault), "# Today")
        XCTAssertNotNil(text(".topo/mirror.json", in: device.obsidianVault))
        // The source is gone: what was carried, then the folders it left empty, then itself.
        XCTAssertNil(contents(of: device.local))
        XCTAssertNil(memory.stranded)
        XCTAssertNil(memory.moveError)
        XCTAssertEqual(memory.home.folder, device.obsidianVault)
        XCTAssertEqual(memory.homeSummary, "iCloud Drive › Obsidian › Memory")
    }

    /// The commit is the write of the home, and nothing before it has changed the source or said
    /// where the vault is. A commit that will not go leaves the memory where it was.
    func testACommitThatFailsLeavesTheHomeAndTheFilesWhereTheyWere() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let bookmarks = InMemoryBookmarkStore()
        let memory = memory(database, on: device, bookmarks: bookmarks)
        await memory.sync()
        struct Refused: Error, CustomStringConvertible { var description = "the keychain said no" }
        bookmarks.refuseSave = Refused()

        let refusal = await memory.keepInICloudDrive(device.obsidianVault)

        XCTAssertNotNil(refusal)
        XCTAssertEqual(memory.home, .local)
        XCTAssertEqual(text("Groceries.md", in: device.local), "eggs")
        XCTAssertNotNil(text(".topo/mirror.json", in: device.local))
        XCTAssertNil(try bookmarks.load())
    }

    /// A destination that cannot be written stops the move before the commit, and the source is
    /// exactly as it was.
    func testACopyThatCannotBeWrittenLeavesTheHomeAndTheFilesWhereTheyWere() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: VaultPath("notes/today.md")!, in: database, as: hub, at: t0)
        let memory = memory(database, on: device)
        await memory.sync()
        let shut = device.obsidianVault.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: shut, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: shut.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shut.path)
        }

        let refusal = await memory.keepInICloudDrive(device.obsidianVault)

        XCTAssertEqual(refusal, "notes/today.md could not be written into the new folder, "
                       + "so the memory stayed where it was")
        XCTAssertEqual(memory.home, .local)
        XCTAssertEqual(text("notes/today.md", in: device.local), "eggs")
    }

    /// After the commit the home has moved, and a file the cleanup carried and could not take
    /// away is something to say rather than a reason to put the memory back.
    func testAFileTheCleanupCannotTakeAwayLeavesTheHomeMovedAndSaysSo() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: VaultPath("notes/today.md")!, in: database, as: hub, at: t0)
        let memory = memory(database, on: device)
        await memory.sync()
        // A folder the file can be read out of and not unlinked from: read and execute, no write.
        let shut = device.local.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: shut.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shut.path)
        }

        let moved = await memory.keepInICloudDrive(device.obsidianVault)

        XCTAssertNil(moved)
        XCTAssertEqual(memory.home.folder, device.obsidianVault)
        XCTAssertEqual(text("notes/today.md", in: device.obsidianVault), "eggs")
        let stranded = try XCTUnwrap(memory.stranded)
        XCTAssertTrue(stranded.isLocal)
        XCTAssertEqual(stranded.names, ["notes/today.md"])
        XCTAssertTrue(memory.summary.contains("the old copy is still on this iPhone"))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shut.path)
        await memory.removeStranded()
        XCTAssertNil(memory.stranded)
        XCTAssertNil(contents(of: device.local))
    }

    /// A name the transfer skipped on purpose was never the memory's to move, so it does not
    /// strand the folder. Reported as left behind it would say the old copy is still there when
    /// the memory has entirely gone — and offer a control to delete the person's own files.
    func testObsidiansOwnFolderDoesNotStrandTheSource() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let memory = memory(database, on: device)
        await memory.sync()
        put("{}", at: ".obsidian/appearance.json", in: device.local)

        let moved = await memory.keepInICloudDrive(device.obsidianVault)

        XCTAssertNil(moved)
        XCTAssertNil(memory.stranded)
        XCTAssertFalse(memory.summary.contains("the old copy"))
        // The folder is not taken away while something of somebody's is still in it.
        XCTAssertEqual(text(".obsidian/appearance.json", in: device.local), "{}")
        XCTAssertNil(text("Groceries.md", in: device.local))
    }

    /// The way back empties the folder the person picked and takes nothing else out of it — and
    /// the retry behind "Remove the old copy" does exactly the same, so a control offered for a
    /// folder in the person's iCloud Drive can never take their Obsidian settings with it.
    func testTheRetryTakesAwayWhatWasCarriedAndNothingElse() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: VaultPath("notes/today.md")!, in: database, as: hub, at: t0)
        let memory = memory(database, on: device)
        await memory.sync()
        let moved = await memory.keepInICloudDrive(device.obsidianVault)
        XCTAssertNil(moved)
        // The person's own things, beside their notes, in the folder they picked.
        put("{}", at: ".obsidian/appearance.json", in: device.obsidianVault)
        let shut = device.obsidianVault.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: shut.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shut.path)
        }

        let back = await memory.keepOnThisPhone()

        XCTAssertNil(back)
        XCTAssertEqual(memory.home, .local)
        XCTAssertEqual(text("notes/today.md", in: device.local), "eggs")
        let stranded = try XCTUnwrap(memory.stranded)
        XCTAssertFalse(stranded.isLocal)
        XCTAssertEqual(stranded.names, ["notes/today.md"])
        // The grant the retry needs, carried on the stranded folder — the home has no scope now.
        XCTAssertEqual(stranded.scope, device.obsidianVault)
        XCTAssertNil(memory.home.scope)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shut.path)
        await memory.removeStranded()

        XCTAssertNil(memory.stranded)
        XCTAssertNil(text("notes/today.md", in: device.obsidianVault))
        // Theirs, untouched, and the folder they picked is still there.
        XCTAssertEqual(text(".obsidian/appearance.json", in: device.obsidianVault), "{}")
        XCTAssertEqual(contents(of: device.obsidianVault), [".obsidian/appearance.json"])
    }

    /// The source is held under a coordinated write from before the first file is read until the
    /// home has moved, so an editor's save does not land in the middle of the copy: it either
    /// went in before, and is carried, or waits and lands in a folder the memory has left.
    func testTheCopyWaitsForACoordinatedWriteOnTheSource() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let memory = memory(database, on: device)
        await memory.sync()

        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [local = device.local] in
            var failure: NSError?
            NSFileCoordinator().coordinate(writingItemAt: local, options: [], error: &failure) { url in
                held.signal()
                // The editor's save, made while this write is held.
                try? Data("eggs, milk".utf8)
                    .write(to: url.appendingPathComponent("Groceries.md"), options: .atomic)
                _ = release.wait(timeout: .now() + 10)
            }
        }
        XCTAssertEqual(held.wait(timeout: .now() + 10), .success)

        let move = Task { await memory.keepInICloudDrive(device.obsidianVault) }
        // While the write is held the copy cannot have run: nothing of it is in the destination.
        for _ in 0..<200 { await Task.yield() }
        XCTAssertNil(text("Groceries.md", in: device.obsidianVault))
        release.signal()

        let refusal = await move.value
        XCTAssertNil(refusal)
        // What the editor wrote is what was carried, whole.
        XCTAssertEqual(text("Groceries.md", in: device.obsidianVault), "eggs, milk")
    }

    /// The baseline travels with the files, so what the folder had been shown is still what its
    /// next local change continues from. A revision another device wrote while the move ran stays
    /// concurrent with the person's edit instead of being re-parented or swallowed.
    func testTheBaselineTravelsSoAConcurrentRevisionStaysConcurrent() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let memory = memory(database, on: device)
        await memory.sync()
        let heads = try await MemoryStore(database: database).read().heads(of: groceries)
        let shown = try XCTUnwrap(heads.first)

        // The person edits in Files; the hub writes its own second revision; then the move runs.
        put("eggs, milk", at: "Groceries.md", in: device.local)
        try await write("eggs, bread", to: groceries, in: database, as: hub,
                        at: t0.addingTimeInterval(60))

        let moved = await memory.keepInICloudDrive(device.obsidianVault)
        XCTAssertNil(moved)
        await memory.sync()

        let vault = try await MemoryStore(database: database).read()
        let mine = vault.notes.values.filter { $0.ref.device == phone && $0.path == groceries }
        XCTAssertEqual(mine.count, 1)
        let written = try XCTUnwrap(mine.first)
        XCTAssertEqual(written.text, "eggs, milk")
        // From the heads the folder was shown before the move, not from what the store holds now.
        XCTAssertEqual(written.parents, [shown])
        // Both survive in the folder: one is the file, the other a conflict copy beside it.
        let names = try XCTUnwrap(contents(of: device.obsidianVault))
        XCTAssertTrue(names.contains("Groceries.md"))
        XCTAssertTrue(names.contains { $0.contains("Conflicted copy") })
    }

    /// The sequence the device test ran: the memory moves to an iCloud Drive folder, Obsidian
    /// makes a note there — which is an empty file — the next pass runs, and then the memory
    /// comes back. The note is a revision by the end of it, and no pass reports it as skipped.
    func testANoteMadeInTheICloudDriveHomeBecomesARevisionAndComesBack() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let memory = memory(database, on: device)
        await memory.sync()
        let moved = await memory.keepInICloudDrive(device.obsidianVault)
        XCTAssertNil(moved)

        // Obsidian makes a note: a file with nothing in it yet.
        put("", at: "Untitled.md", in: device.obsidianVault)
        await memory.sync()

        XCTAssertEqual(memory.lastReport?.skipped, [])
        XCTAssertEqual(memory.lastReport?.pushed.map(\.string), ["Untitled.md"])
        let untitled = VaultPath("Untitled.md")!
        var vault = try await MemoryStore(database: database).read()
        XCTAssertEqual(vault.text(at: untitled), "")

        // And it comes home with everything else.
        let back = await memory.keepOnThisPhone()
        XCTAssertNil(back)
        XCTAssertEqual(text("Untitled.md", in: device.local), "")
        await memory.sync()
        XCTAssertEqual(memory.lastReport?.skipped, [])
        vault = try await MemoryStore(database: database).read()
        XCTAssertEqual(vault.text(at: untitled), "")
        XCTAssertFalse(vault.isForked(untitled))
    }

    /// The way back is the same operation with the folders swapped, and the baseline comes back
    /// with the files.
    func testTheWayBackBringsTheFilesAndTheBaseline() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let bookmarks = InMemoryBookmarkStore()
        let memory = memory(database, on: device, bookmarks: bookmarks)
        await memory.sync()
        let moved = await memory.keepInICloudDrive(device.obsidianVault)
        XCTAssertNil(moved)

        let refusal = await memory.keepOnThisPhone()

        XCTAssertNil(refusal)
        XCTAssertEqual(memory.home, .local)
        XCTAssertNil(try bookmarks.load())
        XCTAssertEqual(text("Groceries.md", in: device.local), "eggs")
        XCTAssertNotNil(text(".topo/mirror.json", in: device.local))
        // The picked folder is the person's and stays; what was carried out of it is gone.
        XCTAssertEqual(contents(of: device.obsidianVault), [])
    }

    // MARK: Every control against every home

    /// A lost home's one way back. There is no folder to read — that is what lost means — so
    /// nothing is carried: the bookmark goes and the folder fills from the store, where every
    /// revision is. Before this, the control the screen offers for a lost home did nothing at
    /// all and said nothing.
    func testALostHomeComesBackToThisPhone() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let bookmarks = InMemoryBookmarkStore(Data("not a bookmark".utf8))
        let memory = memory(database, on: device, bookmarks: bookmarks)
        await memory.sync()
        guard case .lost = memory.home else { return XCTFail("the home is \(memory.home)") }

        let back = await memory.keepOnThisPhone()

        XCTAssertNil(back)
        XCTAssertEqual(memory.home, .local)
        XCTAssertNil(try bookmarks.load())
        XCTAssertEqual(text("Groceries.md", in: device.local), "eggs")
        XCTAssertNil(memory.stranded)
        XCTAssertNil(memory.moveError)
    }

    /// Picking a second folder while the memory already lives in a first one is a move between
    /// them. One that read the source off this app's own folder would carry an empty folder and
    /// leave the memory in the first.
    func testPickingASecondFolderMovesTheMemoryOutOfTheFirst() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let memory = memory(database, on: device)
        await memory.sync()
        let first = await memory.keepInICloudDrive(device.obsidianVault)
        XCTAssertNil(first)

        let second = await memory.keepInICloudDrive(device.iCloudDriveRoot)

        XCTAssertNil(second)
        let made = device.iCloudDriveRoot
            .appendingPathComponent("Obsidian/\(VaultHome.vaultName)", isDirectory: true)
        XCTAssertEqual(memory.home.folder, made)
        XCTAssertEqual(text("Groceries.md", in: made), "eggs")
        XCTAssertNotNil(text(".topo/mirror.json", in: made))
        // The first folder is the person's and stays, emptied of what the memory put in it.
        XCTAssertEqual(contents(of: device.obsidianVault), [])
        XCTAssertNil(memory.stranded)
    }

    /// There is nothing to carry out of a folder that cannot be reached, and nothing here may
    /// say where the memory went. The refusal names the control that does work.
    func testAPickWhileTheHomeIsLostIsRefused() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        let bookmarks = InMemoryBookmarkStore(Data("not a bookmark".utf8))
        let memory = memory(database, on: device, bookmarks: bookmarks)
        await memory.sync()

        let refusal = await memory.keepInICloudDrive(device.obsidianVault)

        XCTAssertEqual(refusal, "the folder the memory is in cannot be reached, so there is "
                       + "nothing to move out of it: keep the memory on this iPhone first, and "
                       + "pick again after")
        guard case .lost = memory.home else { return XCTFail("the home is \(memory.home)") }
        XCTAssertEqual(try bookmarks.load(), Data("not a bookmark".utf8))
        XCTAssertNil(contents(of: device.obsidianVault.appendingPathComponent("Groceries.md")))
    }

    /// A sign-out during a move waits the move out. Its cleanup clears the bookmark and takes
    /// the folder away, and either between the copy and the commit is a move committing a home
    /// the sign-out has just dropped — a signed-out phone holding a live grant on the person's
    /// iCloud Drive folder.
    func testASignOutDuringAMoveWaitsItOutAndStillTakesEverything() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let login = Login()
        let bookmarks = InMemoryBookmarkStore()
        let memory = Memory(directory: device.local, store: MemoryStore(database: database),
                            device: phone, isSignedIn: { login.holds }, bookmarks: bookmarks,
                            ubiquityRoot: device.ubiquityRoot,
                            isUbiquitous: { [ubiquity = device.ubiquityRoot.standardizedFileURL.path] in
                                $0.standardizedFileURL.path.hasPrefix(ubiquity)
                            },
                            warm: { _ in VaultDownloads.Report() }, ensureZone: {},
                            now: { [t0] in t0 })
        await memory.sync()

        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [local = device.local] in
            var failure: NSError?
            NSFileCoordinator().coordinate(writingItemAt: local, options: [], error: &failure) { _ in
                held.signal()
                _ = release.wait(timeout: .now() + 10)
            }
        }
        XCTAssertEqual(held.wait(timeout: .now() + 10), .success)

        let move = Task { await memory.keepInICloudDrive(device.obsidianVault) }
        for _ in 0..<200 { await Task.yield() }
        login.holds = false
        memory.forget()
        release.signal()
        _ = await move.value
        // The sign-out's cleanup runs after the move, whatever the move committed.
        try await eventually("the sign-out to finish") { try bookmarks.load() == nil }
        await memory.sync()

        XCTAssertNil(try bookmarks.load())
        XCTAssertEqual(memory.home, .local)
        XCTAssertNil(contents(of: device.local))
    }

    // MARK: Picks the app will not take

    func testAPickOutsideICloudDriveIsRefusedAndChangesNothing() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let bookmarks = InMemoryBookmarkStore()
        let memory = memory(database, on: device, bookmarks: bookmarks)
        await memory.sync()

        let refusal = await memory.keepInICloudDrive(device.outside)

        XCTAssertEqual(refusal, VaultHome.Refusal.notInICloudDrive.reason)
        XCTAssertEqual(memory.home, .local)
        XCTAssertNil(try bookmarks.load())
        XCTAssertEqual(text("Groceries.md", in: device.local), "eggs")
        XCTAssertEqual(contents(of: device.outside), [])
    }

    func testARootPickMakesAndFillsTheVaultUnderObsidian() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let memory = memory(database, on: device)
        await memory.sync()

        let moved = await memory.keepInICloudDrive(device.iCloudDriveRoot)
        XCTAssertNil(moved)

        let made = device.iCloudDriveRoot
            .appendingPathComponent("Obsidian/\(VaultHome.vaultName)", isDirectory: true)
        XCTAssertEqual(memory.home.folder, made)
        XCTAssertEqual(text("Groceries.md", in: made), "eggs")
        XCTAssertEqual(memory.homeSummary, "iCloud Drive › Obsidian › Topo")
        // The grant stays on what the person handed over, not on the folder made under it.
        XCTAssertEqual(memory.home.scope, device.iCloudDriveRoot)
        // The baseline travels with the files, and the old copy goes.
        XCTAssertNotNil(text(".topo/mirror.json", in: made))
        XCTAssertNil(contents(of: device.local))
    }

    // MARK: A home that cannot be reached

    /// A bookmark that will not resolve is a home nothing runs against — not a reason to fill this
    /// phone with a memory the person asked to keep somewhere else.
    func testALostBookmarkStopsEveryPass() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let bookmarks = InMemoryBookmarkStore(Data("not a bookmark".utf8))
        let memory = memory(database, on: device, bookmarks: bookmarks)

        await memory.sync()

        guard case .lost = memory.home else { return XCTFail("the home is \(memory.home)") }
        XCTAssertNil(memory.lastReport)
        XCTAssertNil(memory.lastSync)
        XCTAssertNil(contents(of: device.local))
        XCTAssertTrue(memory.summary.contains("lost"))
    }

    // MARK: The offer

    func testTheOfferStandsOnlyOnceAndOnlyWhileTheMemoryIsOnThisPhone() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        for index in 0...Memory.offerThreshold {
            try await write("note", to: VaultPath("note-\(index).md")!, in: database, as: hub, at: t0)
        }
        let memory = memory(database, on: device)
        await memory.sync()

        XCTAssertTrue(memory.offersICloudDrive(answered: false))
        // Not now, and the card is gone for good: the answer is the caller's to remember, and
        // this says nothing more once it has been given.
        XCTAssertFalse(memory.offersICloudDrive(answered: true))

        let moved = await memory.keepInICloudDrive(device.obsidianVault)
        XCTAssertNil(moved)
        // Nothing to offer once the memory is already there.
        XCTAssertFalse(memory.offersICloudDrive(answered: false))
    }

    func testAVaultWithAHandfulInItIsNotOfferedAnything() async throws {
        let device = makeDevice()
        let database = InMemoryRecordDatabase()
        try await write("eggs", to: groceries, in: database, as: hub, at: t0)
        let memory = memory(database, on: device)
        await memory.sync()

        XCTAssertEqual(memory.lastReport?.files, 1)
        XCTAssertFalse(memory.offersICloudDrive(answered: false))
    }
}

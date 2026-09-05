import Foundation
import Testing
import TopoCore
import TopoCoreTesting

@Suite struct VaultMirrorTests {
    let db = InMemoryRecordDatabase()
    var store: MemoryStore { MemoryStore(database: db) }
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let note = VaultPath("Meeting notes.md")!

    /// A directory of its own for one test, taken away afterwards.
    private func inTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("topo-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    private func write(_ text: String, to path: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(path)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @Test func theStoreArrivesOnDiskAsPlainMarkdown() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("# Helen", to: VaultPath("people/helen.md")!, continuing: store.read(), at: t0)

            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            let report = try await mirror.sync(at: t0 + 1)
            #expect(report.written == [VaultPath("people/helen.md")!])
            #expect(read("people/helen.md", in: directory) == "# Helen")

            // Nothing changed since, so nothing to do.
            #expect(try await mirror.sync(at: t0 + 2).isEmpty)
        }
    }

    @Test func aFileWrittenInTheFolderBecomesARevision() async throws {
        try await inTemporaryDirectory { directory in
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try write("what I remember", to: "Meeting notes.md", in: directory)

            let report = try await mirror.sync(at: t0)
            #expect(report.pushed == [note])
            #expect(try await store.read().text(at: note) == "what I remember")

            try write("what I remember, corrected", to: "Meeting notes.md", in: directory)
            #expect(try await mirror.sync(at: t0 + 1).pushed == [note])
            #expect(try await store.read().text(at: note) == "what I remember, corrected")
            #expect(try await store.read().isForked(note) == false)
        }
    }

    @Test func aFileRemovedFromTheFolderIsRemovedFromTheStore() async throws {
        try await inTemporaryDirectory { directory in
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try write("temporary", to: "Meeting notes.md", in: directory)
            try await mirror.sync(at: t0)

            try FileManager.default.removeItem(at: directory.appendingPathComponent("Meeting notes.md"))
            let report = try await mirror.sync(at: t0 + 1)
            #expect(report.deleted == [note])
            #expect(try await store.read().files[note] == nil)
        }
    }

    @Test func aFileRemovedElsewhereGoesFromTheFolder() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("passing thought", to: note, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 1)
            #expect(read("Meeting notes.md", in: directory) != nil)

            try await w.delete(note, continuing: store.read(), at: t0 + 2)
            #expect(try await mirror.sync(at: t0 + 3).removed == [note])
            #expect(read("Meeting notes.md", in: directory) == nil)
        }
    }

    @Test func whatIsNotTheVaultsIsLeftWhereItIs() async throws {
        try await inTemporaryDirectory { directory in
            try write("{}", to: ".obsidian/app.json", in: directory)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("art"),
                                                    withIntermediateDirectories: true)
            try Data([0xFF, 0xFE, 0x00]).write(to: directory.appendingPathComponent("art/sketch.bin"))

            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            let report = try await mirror.sync(at: t0)
            #expect(report.skipped == ["art/sketch.bin"])
            #expect(report.pushed.isEmpty)
            #expect(try await store.read().isEmpty)
            #expect(read(".obsidian/app.json", in: directory) == "{}")
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("art/sketch.bin").path))
        }
    }

    @Test func aLinkOutOfTheVaultIsNeverRead() async throws {
        try await inTemporaryDirectory { directory in
            try await inTemporaryDirectory { elsewhere in
                let secret = elsewhere.appendingPathComponent("secrets.txt")
                try Data("nobody put this in the vault".utf8).write(to: secret)
                try FileManager.default.createSymbolicLink(
                    at: directory.appendingPathComponent("secrets.md"), withDestinationURL: secret)
                try write("mine", to: "Meeting notes.md", in: directory)

                let mirror = VaultMirror(directory: directory, store: store, device: phone)
                let report = try await mirror.sync(at: t0)
                #expect(report.skipped == ["secrets.md"])
                #expect(report.pushed == [note])
                let vault = try await store.read()
                #expect(vault.ordered.map(\.path) == [note])
                #expect(vault.text(at: VaultPath("secrets.md")!) == nil)
                // The link is left exactly where it was.
                #expect(read("secrets.txt", in: elsewhere) == "nobody put this in the vault")
            }
        }
    }

    @Test func aLinkWhereAFileShouldGoIsNotWrittenThrough() async throws {
        try await inTemporaryDirectory { directory in
            try await inTemporaryDirectory { elsewhere in
                let target = elsewhere.appendingPathComponent("theirs.txt")
                try Data("not ours to write".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(
                    at: directory.appendingPathComponent("Meeting notes.md"), withDestinationURL: target)

                let w = try await store.writer(for: hub)
                try await w.write("from the hub", to: note, continuing: store.read(), at: t0)
                let mirror = VaultMirror(directory: directory, store: store, device: phone)
                let report = try await mirror.sync(at: t0 + 1)
                #expect(report.written.isEmpty)
                #expect(report.skipped == ["Meeting notes.md"])
                #expect(read("theirs.txt", in: elsewhere) == "not ours to write")
            }
        }
    }

    @Test func aFileWhereACopyWouldGoIsAFileOfItsOwn() async throws {
        try await inTemporaryDirectory { directory in
            let one = try await store.writer(for: phone)
            let other = try await store.writer(for: hub)
            let empty = try await store.read()
            try await one.write("from the phone", to: note, continuing: empty, at: t0)
            try await other.write("from the hub", to: note, continuing: empty, at: t0 + 10)

            // Made by the person, at the name a copy of this fork wants,
            // before any sync has put a copy there.
            let name = "Meeting notes (Conflicted copy phone 197001121346).md"
            try write("nothing to do with the fork", to: name, in: directory)

            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 20)
            let vault = try await store.read()
            #expect(vault.isForked(note))
            #expect(vault.text(at: VaultPath(name)!) == "nothing to do with the fork")
            #expect(read(name, in: directory) == "nothing to do with the fork")
            // The copy went somewhere else rather than over it.
            #expect(read("Meeting notes (Conflicted copy phone 197001121346 1).md", in: directory) == "from the phone")
        }
    }

    @Test func aConflictAppearsInTheFolderAsACopyBesideTheFile() async throws {
        try await inTemporaryDirectory { directory in
            let one = try await store.writer(for: phone)
            let other = try await store.writer(for: hub)
            let empty = try await store.read()
            try await one.write("from the phone", to: note, continuing: empty, at: t0)
            try await other.write("from the hub", to: note, continuing: empty, at: t0 + 10)

            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 20)
            #expect(read("Meeting notes.md", in: directory) == "from the hub")
            #expect(read("Meeting notes (Conflicted copy phone 197001121346).md", in: directory) == "from the phone")
        }
    }

    @Test func deletingTheCopySettlesTheForkOnTheFile() async throws {
        try await inTemporaryDirectory { directory in
            let one = try await store.writer(for: phone)
            let other = try await store.writer(for: hub)
            let empty = try await store.read()
            try await one.write("from the phone", to: note, continuing: empty, at: t0)
            try await other.write("from the hub", to: note, continuing: empty, at: t0 + 10)

            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 20)
            let copy = "Meeting notes (Conflicted copy phone 197001121346).md"
            try FileManager.default.removeItem(at: directory.appendingPathComponent(copy))

            let report = try await mirror.sync(at: t0 + 30)
            #expect(report.pushed == [note])
            let vault = try await store.read()
            #expect(!vault.isForked(note))
            #expect(vault.text(at: note) == "from the hub")
            #expect(read(copy, in: directory) == nil)
            #expect(read("Meeting notes.md", in: directory) == "from the hub")
            #expect(try await mirror.sync(at: t0 + 40).isEmpty)
        }
    }

    @Test func editingTheCopyMergesItIntoTheFile() async throws {
        try await inTemporaryDirectory { directory in
            let one = try await store.writer(for: phone)
            let other = try await store.writer(for: hub)
            let empty = try await store.read()
            try await one.write("from the phone", to: note, continuing: empty, at: t0)
            try await other.write("from the hub", to: note, continuing: empty, at: t0 + 10)

            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 20)
            let copy = "Meeting notes (Conflicted copy phone 197001121346).md"
            try write("from both", to: copy, in: directory)

            #expect(try await mirror.sync(at: t0 + 30).pushed == [note])
            let vault = try await store.read()
            #expect(!vault.isForked(note))
            #expect(vault.text(at: note) == "from both")
            #expect(read(copy, in: directory) == nil)
            #expect(read("Meeting notes.md", in: directory) == "from both")
        }
    }

    @Test func anEditMadeElsewhereSinceTheLastSyncIsNotSwallowed() async throws {
        try await inTemporaryDirectory { directory in
            let elsewhere = try await store.writer(for: hub)
            try await elsewhere.write("first", to: note, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 1)

            // The other device moves on; this folder is never told.
            try await elsewhere.write("what the hub says", to: note, continuing: store.read(), at: t0 + 2)
            // Meanwhile the person edits what they can see, which is "first".
            try write("what I say", to: "Meeting notes.md", in: directory)

            try await mirror.sync(at: t0 + 3)
            let vault = try await store.read()
            // The two edits never saw each other, so neither replaces the
            // other: this one is newer and is the file, the hub's is beside it.
            #expect(vault.isForked(note))
            #expect(vault.text(at: note) == "what I say")
            let copy = "Meeting notes (Conflicted copy hub 197001121346).md"
            #expect(read(copy, in: directory) == "what the hub says")
            #expect(read("Meeting notes.md", in: directory) == "what I say")
        }
    }

    @Test func aDeletionHereDoesNotSwallowAnEditMadeElsewhere() async throws {
        try await inTemporaryDirectory { directory in
            let elsewhere = try await store.writer(for: hub)
            try await elsewhere.write("first", to: note, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 1)

            try await elsewhere.write("still wanted", to: note, continuing: store.read(), at: t0 + 2)
            try FileManager.default.removeItem(at: directory.appendingPathComponent("Meeting notes.md"))

            #expect(try await mirror.sync(at: t0 + 3).deleted == [note])
            let vault = try await store.read()
            #expect(vault.files[note] == nil)
            #expect(read("Meeting notes.md", in: directory) == nil)
            let copy = "Meeting notes (Conflicted copy hub 197001121346).md"
            #expect(read(copy, in: directory) == "still wanted")
        }
    }

    @Test func aFolderWithSeveralAnswersToOneForkWritesOneRevision() async throws {
        try await inTemporaryDirectory { directory in
            let one = try await store.writer(for: phone)
            let other = try await store.writer(for: hub)
            let empty = try await store.read()
            try await one.write("from the phone", to: note, continuing: empty, at: t0)
            try await other.write("from the hub", to: note, continuing: empty, at: t0 + 10)

            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 20)
            // The person merges by hand and throws the copy away.
            try write("from both", to: "Meeting notes.md", in: directory)
            try FileManager.default.removeItem(
                at: directory.appendingPathComponent("Meeting notes (Conflicted copy phone 197001121346).md"))

            #expect(try await mirror.sync(at: t0 + 30).pushed == [note])
            let vault = try await store.read()
            #expect(!vault.isForked(note))
            #expect(vault.text(at: note) == "from both")
            #expect(vault.notes.count == 3)
        }
    }

    @Test func twoFoldersOverOneStoreEndUpTheSame() async throws {
        try await inTemporaryDirectory { here in
            try await inTemporaryDirectory { there in
                let mine = VaultMirror(directory: here, store: store, device: phone)
                let theirs = VaultMirror(directory: there, store: store, device: hub)
                try write("first", to: "shared/list.md", in: here)
                try await mine.sync(at: t0)
                try await theirs.sync(at: t0 + 1)
                #expect(read("shared/list.md", in: there) == "first")

                try write("first\nsecond", to: "shared/list.md", in: there)
                try await theirs.sync(at: t0 + 2)
                try await mine.sync(at: t0 + 3)
                #expect(read("shared/list.md", in: here) == "first\nsecond")
                #expect(try await store.read().isForked(VaultPath("shared/list.md")!) == false)
            }
        }
    }

    @Test func anIncompleteReadStopsTheSyncRatherThanActOnIt() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("one", to: note, continuing: store.read(), at: t0)
            try await w.write("two", to: note, continuing: store.read(), at: t0 + 1)

            let stale = MemoryStore(database: StaleTailDatabase(inner: db))
            let mirror = VaultMirror(directory: directory, store: stale, device: phone)
            await #expect(throws: MemoryError.self) { try await mirror.sync(at: t0 + 2) }
            #expect(read("Meeting notes.md", in: directory) == nil)
        }
    }
}

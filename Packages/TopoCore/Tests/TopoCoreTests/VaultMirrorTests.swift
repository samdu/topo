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

    @Test func aFolderAndAFileOfTheSameNameBothReachTheFolder() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("a note called notes", to: VaultPath("notes")!, continuing: store.read(), at: t0)
            try await w.write("today's note", to: VaultPath("notes/today.md")!, continuing: store.read(), at: t0 + 1)

            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            let report = try await mirror.sync(at: t0 + 2)
            #expect(report.skipped.isEmpty)
            #expect(read("notes/today.md", in: directory) == "today's note")
            #expect(read("notes (Conflicted copy hub 197001121346)", in: directory) == "a note called notes")
            // And it settles: a second sync has nothing left to do.
            #expect(try await mirror.sync(at: t0 + 3).isEmpty)
        }
    }

    @Test func aFolderThatBecomesAFileIsMadeWayFor() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            let inside = VaultPath("notes/today.md")!
            try await w.write("today's note", to: inside, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 1)
            #expect(read("notes/today.md", in: directory) == "today's note")

            // Elsewhere the folder's one file goes and a file takes its name.
            try await w.delete(inside, continuing: store.read(), at: t0 + 2)
            try await w.write("a note called notes", to: VaultPath("notes")!, continuing: store.read(), at: t0 + 3)

            let report = try await mirror.sync(at: t0 + 4)
            #expect(report.skipped.isEmpty)
            #expect(read("notes", in: directory) == "a note called notes")
            #expect(try await mirror.sync(at: t0 + 5).isEmpty)
        }
    }

    @Test func aLinkedFolderIsNotWrittenThrough() async throws {
        try await inTemporaryDirectory { directory in
            try await inTemporaryDirectory { elsewhere in
                let target = elsewhere.appendingPathComponent("theirs.md")
                try Data("not ours to write".utf8).write(to: target)
                // A link standing in for a folder inside the vault.
                try FileManager.default.createSymbolicLink(
                    at: directory.appendingPathComponent("linked"), withDestinationURL: elsewhere)

                let w = try await store.writer(for: hub)
                try await w.write("from the hub", to: VaultPath("linked/theirs.md")!,
                                  continuing: store.read(), at: t0)
                let mirror = VaultMirror(directory: directory, store: store, device: phone)
                let report = try await mirror.sync(at: t0 + 1)
                #expect(report.written.isEmpty)
                #expect(report.skipped == ["linked", "linked/theirs.md"])
                #expect(read("theirs.md", in: elsewhere) == "not ours to write")
            }
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

    /// The folder is shared, so the window between the scan and the store read
    /// belongs to whoever else has it open. What they wrote in it is an edit,
    /// not something for the download to land on top of.
    @Test func anEditMadeWhileTheStoreIsReadBecomesARevisionRatherThanBeingOverwritten() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("from the hub", to: note, continuing: store.read(), at: t0)

            let interrupted = InterruptedFeedDatabase(inner: db)
            let directoryPath = directory.appendingPathComponent("Meeting notes.md")
            await interrupted.onFirstFeedRead {
                try? Data("typed on the phone".utf8).write(to: directoryPath)
            }
            let mirror = VaultMirror(directory: directory, store: MemoryStore(database: interrupted), device: phone)
            // The edit is the newer of the two, so it is the file and the hub's
            // revision is the copy beside it.
            let report = try await mirror.sync(at: t0 + 10)

            #expect(report.pushed == [note])
            #expect(read("Meeting notes.md", in: directory) == "typed on the phone")
            let vault = try await store.read()
            #expect(vault.isForked(note))
            #expect(vault.text(at: note) == "typed on the phone")
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let copies = files.filter { $0.contains("Conflicted copy") }
            #expect(copies.count == 1)
            #expect(read(copies[0], in: directory) == "from the hub")
        }
    }

    /// The same window, with the store holding the newer revision: what was
    /// downloaded is the file, and the edit made meanwhile is the copy beside
    /// it. The file at that path does change — what must not happen is the
    /// edit going unrecorded.
    @Test func anEditMadeWhileTheStoreIsReadSurvivesAsACopyWhenTheStoreIsNewer() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("from the hub", to: note, continuing: store.read(), at: t0 + 100)

            let interrupted = InterruptedFeedDatabase(inner: db)
            let file = directory.appendingPathComponent("Meeting notes.md")
            await interrupted.onFirstFeedRead {
                try? Data("typed on the phone".utf8).write(to: file)
            }
            let mirror = VaultMirror(directory: directory, store: MemoryStore(database: interrupted), device: phone)
            let report = try await mirror.sync(at: t0 + 10)

            #expect(report.pushed == [note])
            #expect(read("Meeting notes.md", in: directory) == "from the hub")
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let copies = files.filter { $0.contains("Conflicted copy") }
            #expect(copies.count == 1)
            #expect(read(copies[0], in: directory) == "typed on the phone")
        }
    }

    /// The same compare, on the other kind of mutation: a file the store no longer holds
    /// is taken off disk only if the folder still holds what the scan saw. Somebody's edit
    /// of it, landing while the store was being read, is kept and becomes a revision
    /// instead — the removal would otherwise take their words with it.
    @Test func aFileEditedWhileTheStoreIsReadIsNotTakenAwayByARemoval() async throws {
        try await inTemporaryDirectory { directory in
            // The folder and the store agree, and then the store's copy is deleted
            // elsewhere, so the next sync's job is to take the file off disk.
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try write("what I remember", to: "Meeting notes.md", in: directory)
            try await mirror.sync(at: t0)
            let elsewhere = try await store.writer(for: hub)
            try await elsewhere.delete(note, continuing: store.read(), at: t0 + 1)

            let interrupted = InterruptedFeedDatabase(inner: db)
            let file = directory.appendingPathComponent("Meeting notes.md")
            await interrupted.onFirstFeedRead {
                try? Data("second thoughts".utf8).write(to: file)
            }
            let racing = VaultMirror(directory: directory, store: MemoryStore(database: interrupted), device: phone)
            // The same folder, so it carries the state the first sync left.
            let report = try await racing.sync(at: t0 + 10)

            #expect(report.removed.isEmpty, "the file was not the one the scan saw")
            #expect(report.pushed == [note])
            #expect(read("Meeting notes.md", in: directory) == "second thoughts")
            #expect(try await store.read().text(at: note) == "second thoughts")
        }
    }

    /// A link swapped in where the scan saw a file, while the store was being read. The
    /// read that decides whether to overwrite opens the path itself and refuses a link, so
    /// what the link points at is never read as this folder's and never becomes a revision.
    @Test func aLinkSwappedInBeforeTheWriteIsRefusedRatherThanReadThrough() async throws {
        try await inTemporaryDirectory { directory in
            try await inTemporaryDirectory { elsewhere in
                let outside = elsewhere.appendingPathComponent("theirs.md")
                try Data("not ours to read".utf8).write(to: outside)

                // The folder and the store agree, and then the store moves on, so the next
                // sync's job is to write the newer text over the file.
                let w = try await store.writer(for: hub)
                try await w.write("from the hub", to: note, continuing: store.read(), at: t0)
                let mirror = VaultMirror(directory: directory, store: store, device: phone)
                try await mirror.sync(at: t0 + 1)
                try await w.write("from the hub, again", to: note, continuing: store.read(), at: t0 + 2)

                let interrupted = InterruptedFeedDatabase(inner: db)
                let file = directory.appendingPathComponent("Meeting notes.md")
                await interrupted.onFirstFeedRead {
                    try? FileManager.default.removeItem(at: file)
                    try? FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
                }
                let racing = VaultMirror(directory: directory, store: MemoryStore(database: interrupted),
                                         device: phone)
                let report = try await racing.sync(at: t0 + 3)

                #expect(report.skipped == ["Meeting notes.md"])
                #expect(report.written.isEmpty)
                #expect(report.pushed.isEmpty)
                let vault = try await store.read()
                #expect(vault.notes.values.contains { $0.text.contains("not ours") } == false,
                        "nothing from outside the vault reached the store")
                #expect(vault.text(at: note) == "from the hub, again")
                #expect(read("theirs.md", in: elsewhere) == "not ours to read")
            }
        }
    }

    /// Cancelled after the first fence, in the middle of making a writer: the revision it
    /// was about to write is not written, and the folder is left as the person left it.
    /// A draft saved into the folder while the sync waits to take that folder away. Whether
    /// the folder is empty is asked at the moment it would go, not before the wait: what the
    /// person saved a second ago is a file of theirs, and the store's file of the same name
    /// waits for the folder rather than taking it.
    @Test func aFileSavedIntoAFolderAboutToBeMadeWayForIsNotTakenWithIt() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            let inside = VaultPath("notes/today.md")!
            try await w.write("today's note", to: inside, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 1)

            // The folder's one file goes and a file takes its name, so the next sync's job
            // is to make way for it.
            try await w.delete(inside, continuing: store.read(), at: t0 + 2)
            try await w.write("a note called notes", to: VaultPath("notes")!, continuing: store.read(), at: t0 + 3)

            // Somebody else has the name open, so the sync waits — and while it waits, they
            // save a draft into the folder it was about to take away.
            let holder = CoordinatedHolder(url: directory.appendingPathComponent("notes"))
            holder.take()
            let sync = Task { try await mirror.sync(at: t0 + 4) }
            try await Task.sleep(for: .milliseconds(200))
            try Data("half a thought".utf8).write(to: directory.appendingPathComponent("notes/draft.md"))
            holder.release()

            let report = try await sync.value
            #expect(read("notes/draft.md", in: directory) == "half a thought")
            #expect(report.skipped == ["notes"], "the store's file waits for the folder")
            #expect(report.written.isEmpty)
            // And the draft is the person's word on it: the next sync makes it a revision.
            #expect(try await mirror.sync(at: t0 + 5).pushed == [VaultPath("notes/draft.md")!])
        }
    }

    /// A folder swapped for a link *above* the file, after the way down has been judged and
    /// while the sync waits for another app's access to the file itself. An open of the file
    /// alone refuses a link standing at its own name and nothing above it, so this is the way
    /// out of the vault that the folder's own descriptor is opened to refuse.
    @Test func aFolderSwappedForALinkWhileTheWriteWaitsIsRefusedRatherThanFollowed() async throws {
        try await inTemporaryDirectory { directory in
            try await inTemporaryDirectory { elsewhere in
                let outside = elsewhere.appendingPathComponent("today.md")
                try Data("not ours to read".utf8).write(to: outside)

                let inside = VaultPath("notes/today.md")!
                let w = try await store.writer(for: hub)
                try await w.write("from the hub", to: inside, continuing: store.read(), at: t0)
                let mirror = VaultMirror(directory: directory, store: store, device: phone)
                try await mirror.sync(at: t0 + 1)
                try await w.write("from the hub, again", to: inside, continuing: store.read(), at: t0 + 2)

                // The sync waits for the file, which is past every look it took at the way
                // down to it; the folder it looked at is a link by the time it is let through.
                let holder = CoordinatedHolder(url: directory.appendingPathComponent("notes/today.md"))
                holder.take()
                let sync = Task { try await mirror.sync(at: t0 + 3) }
                try await Task.sleep(for: .milliseconds(200))
                try FileManager.default.removeItem(at: directory.appendingPathComponent("notes"))
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("notes"),
                                                           withDestinationURL: elsewhere)
                holder.release()

                let report = try await sync.value
                #expect(report.skipped == ["notes/today.md"])
                #expect(report.written.isEmpty)
                #expect(report.pushed.isEmpty)
                #expect(read("today.md", in: elsewhere) == "not ours to read", "not written")
                let vault = try await store.read()
                #expect(vault.notes.values.contains { $0.text.contains("not ours") } == false,
                        "and not read: nothing from outside the vault reached the store")
                #expect(vault.text(at: inside) == "from the hub, again")
            }
        }
    }

    /// The same swap, on the way to a file being taken away rather than written. The removal
    /// opens the folder it unlinks from for itself, and a link above it is refused there too —
    /// otherwise a deletion in the store deletes somebody else's file outside the vault.
    @Test func aFolderSwappedForALinkWhileTheRemovalWaitsCarriesNothingOutOfTheVault() async throws {
        try await inTemporaryDirectory { directory in
            try await inTemporaryDirectory { elsewhere in
                try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("sub"),
                                                        withIntermediateDirectories: true)
                // The same words the vault's file holds, so that nothing but the link guard
                // stands between the removal and somebody else's file: a compare against what
                // the scan saw would let this one through.
                try Data("from the hub".utf8).write(to: elsewhere.appendingPathComponent("sub/old.md"))

                let inside = VaultPath("sub/old.md")!
                let w = try await store.writer(for: hub)
                try await w.write("from the hub", to: inside, continuing: store.read(), at: t0)
                let mirror = VaultMirror(directory: directory, store: store, device: phone)
                try await mirror.sync(at: t0 + 1)
                try await w.delete(inside, continuing: store.read(), at: t0 + 2)

                let holder = CoordinatedHolder(url: directory.appendingPathComponent("sub/old.md"))
                holder.take()
                let sync = Task { try await mirror.sync(at: t0 + 3) }
                try await Task.sleep(for: .milliseconds(200))
                try FileManager.default.removeItem(at: directory.appendingPathComponent("sub"))
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("sub"),
                                                           withDestinationURL: elsewhere.appendingPathComponent("sub"))
                holder.release()

                let report = try await sync.value
                #expect(report.removed.isEmpty)
                #expect(report.skipped == ["sub/old.md"])
                #expect(read("sub/old.md", in: elsewhere) == "from the hub",
                        "somebody else's file, taken away by a deletion in the store")
            }
        }
    }

    /// An empty folder at the scan, so nothing of the vault's is coordinated under it and the
    /// removal of the folder is the sync's first wait — the far side of where a look at whether
    /// it is empty used to be taken.
    @Test func aSaveIntoAnEmptyFolderDuringTheRemovalWaitSurvives() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("a note called notes", to: VaultPath("notes")!, continuing: store.read(), at: t0)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("notes"),
                                                    withIntermediateDirectories: true)

            let holder = CoordinatedHolder(url: directory.appendingPathComponent("notes"))
            holder.take()
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            let sync = Task { try await mirror.sync(at: t0 + 1) }
            try await Task.sleep(for: .milliseconds(300))
            try Data("half a thought".utf8).write(to: directory.appendingPathComponent("notes/draft.md"))
            holder.release()

            _ = try await sync.value
            #expect(read("notes/draft.md", in: directory) == "half a thought")
        }
    }

    /// A folder above the one being made way for, swapped for a link while that removal waits.
    @Test func aFolderIsNotTakenAwayThroughALinkSwappedInAboveIt() async throws {
        try await inTemporaryDirectory { directory in
            try await inTemporaryDirectory { elsewhere in
                try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("notes"),
                                                        withIntermediateDirectories: true)
                try Data("not ours to take".utf8).write(to: elsewhere.appendingPathComponent("notes/keep.md"))

                let w = try await store.writer(for: hub)
                try await w.write("a note called notes", to: VaultPath("sub/notes")!,
                                  continuing: store.read(), at: t0)
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub/notes"),
                                                        withIntermediateDirectories: true)

                let holder = CoordinatedHolder(url: directory.appendingPathComponent("sub/notes"))
                holder.take()
                let mirror = VaultMirror(directory: directory, store: store, device: phone)
                let sync = Task { try await mirror.sync(at: t0 + 1) }
                try await Task.sleep(for: .milliseconds(300))
                try FileManager.default.removeItem(at: directory.appendingPathComponent("sub"))
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("sub"),
                                                           withDestinationURL: elsewhere)
                holder.release()

                _ = try? await sync.value
                #expect(read("notes/keep.md", in: elsewhere) == "not ours to take")
            }
        }
    }

    /// The window the whole design is about, driven end to end: the compare against what the
    /// scan saw and the replacement are one coordinated write, so a save that lands while the
    /// sync waits for the file is found by the compare rather than flattened by the write.
    @Test func aSaveThatLandsWhileTheWriteWaitsBecomesARevisionRatherThanBeingOverwritten() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("from the hub", to: note, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 1)
            try await w.write("from the hub, again", to: note, continuing: store.read(), at: t0 + 2)

            // The person's editor has the file, and saves into it while the sync waits.
            let holder = CoordinatedHolder(url: directory.appendingPathComponent("Meeting notes.md"))
            holder.take()
            let sync = Task { try await mirror.sync(at: t0 + 3) }
            try await Task.sleep(for: .milliseconds(200))
            try Data("what I typed".utf8).write(to: directory.appendingPathComponent("Meeting notes.md"))
            holder.release()

            let report = try await sync.value
            #expect(report.pushed == [note], "their save is a revision of their own")
            #expect(read("Meeting notes.md", in: directory) == "what I typed", "and stands where they left it")
            let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.contains("Conflicted copy") }
            #expect(copies.count == 1, "the hub's words are beside it, not on top of it")
            #expect(copies.first.flatMap { read($0, in: directory) } == "from the hub, again")
            #expect(try await store.read().text(at: note) == "what I typed")
        }
    }

    /// The baseline is written under coordination too: somebody holding the mirror's own state
    /// file is waited out, and the save lands when they let go.
    @Test func theStateIsWrittenUnderCoordinationAndWaitsForWhoeverHoldsIt() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("from the hub", to: note, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 1)
            let before = read(".topo/mirror.json", in: directory)
            let second = VaultPath("people/helen.md")!
            try await w.write("# Helen", to: second, continuing: store.read(), at: t0 + 2)

            let holder = CoordinatedHolder(url: directory.appendingPathComponent(".topo/mirror.json"))
            holder.take()
            let sync = Task { try await mirror.sync(at: t0 + 3) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(read("people/helen.md", in: directory) == "# Helen", "the file went down first")
            #expect(read(".topo/mirror.json", in: directory) == before, "and the save is waiting for them")
            holder.release()

            _ = try await sync.value
            #expect(read(".topo/mirror.json", in: directory)?.contains("helen.md") == true)
            #expect(read("Meeting notes.md", in: directory) == "from the hub", "and nothing else moved")
        }
    }

    /// Cancelled at the last thing a pass does. The baseline says what this folder has been
    /// shown, so writing one for a pass that stopped is a claim about a folder nobody filled.
    @Test func aSyncCancelledAtTheStateSaveLeavesTheBaselineAsItWas() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("from the hub", to: note, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            try await mirror.sync(at: t0 + 1)
            let before = read(".topo/mirror.json", in: directory)
            #expect(before?.contains("Meeting notes.md") == true)

            // A second note, so the pass has something to write before it reaches the save.
            let second = VaultPath("people/helen.md")!
            try await w.write("# Helen", to: second, continuing: store.read(), at: t0 + 2)

            let holder = CoordinatedHolder(url: directory.appendingPathComponent(".topo/mirror.json"))
            holder.take()
            let sync = Task { try await mirror.sync(at: t0 + 3) }
            try await Task.sleep(for: .milliseconds(200))
            sync.cancel()
            holder.release()

            await #expect(throws: CancellationError.self) { try await sync.value }
            #expect(read(".topo/mirror.json", in: directory) == before,
                    "a pass that stopped wrote a baseline for what it did not finish")
            #expect(read("people/helen.md", in: directory) == "# Helen", "what it did write stands")
        }
    }

    /// Cancelled while the coordinator holds the sync waiting on another app's access to
    /// the very file it is about to write. That wait is as long as the other app likes,
    /// and a sync abandoned during it has nothing to write when its turn comes.
    @Test func aSyncCancelledWhileItWaitsForAnotherAccessorWritesNothing() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("from the hub", to: note, continuing: store.read(), at: t0)

            // Somebody else has the file open for writing, so the mirror's write waits.
            let holder = CoordinatedHolder(url: directory.appendingPathComponent("Meeting notes.md"))
            holder.take()
            #expect(holder.isHolding)

            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            let sync = Task { try await mirror.sync(at: t0 + 1) }
            // Long enough for the sync to be past its fences and inside the coordinator,
            // which is where this test wants it: nothing here waits on iCloud or on time,
            // and the holder is what it is waiting for.
            try await Task.sleep(for: .milliseconds(200))
            #expect(read("Meeting notes.md", in: directory) == nil, "the write is waiting, not done")

            sync.cancel()
            holder.release()

            await #expect(throws: CancellationError.self) { try await sync.value }
            #expect(read("Meeting notes.md", in: directory) == nil, "and it stayed waiting-and-gone")
        }
    }

    /// And the same where the file is to be taken away: the removal waits behind another
    /// app's access too, and a cancelled sync takes nothing away when it is let through.
    @Test func aSyncCancelledWhileItWaitsToRemoveAFileTakesNothingAway() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("from the hub", to: note, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            _ = try await mirror.sync(at: t0 + 1)
            try await w.delete(note, continuing: store.read(), at: t0 + 2)

            let holder = CoordinatedHolder(url: directory.appendingPathComponent("Meeting notes.md"))
            holder.take()
            let sync = Task { try await mirror.sync(at: t0 + 3) }
            try await Task.sleep(for: .milliseconds(200))
            sync.cancel()
            holder.release()

            await #expect(throws: CancellationError.self) { try await sync.value }
            #expect(read("Meeting notes.md", in: directory) == "from the hub")
        }
    }

    @Test func aSyncCancelledAfterTheFirstFenceWritesNoRevision() async throws {
        try await inTemporaryDirectory { directory in
            try write("what I remember", to: "Meeting notes.md", in: directory)
            let interrupted = InterruptedQueryDatabase(inner: db)
            let mirror = VaultMirror(directory: directory, store: MemoryStore(database: interrupted), device: phone)

            let sync = Task { try await mirror.sync(at: t0) }
            // The writer's own query, which is past the fence after the store was read
            // and before any revision is written.
            await interrupted.onFirstQuery { sync.cancel() }
            await #expect(throws: CancellationError.self) { try await sync.value }

            #expect(try await store.read().knownPaths.isEmpty, "no revision was written")
            #expect(read("Meeting notes.md", in: directory) == "what I remember")
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".topo").path) == false)
        }
    }

    /// Cancelled before the actor ran it at all — a sign-out between the cue and the pass.
    /// Making the folder is already a change to the person's phone, so a phone that is not
    /// to have one is left without one rather than with an empty folder nothing will fill.
    @Test func aSyncCancelledBeforeItRunsMakesNoFolder() async throws {
        try await inTemporaryDirectory { parent in
            let directory = parent.appendingPathComponent("Vault", isDirectory: true)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)

            let gate = Gate()
            let sync = Task {
                await gate.wait()
                return try await mirror.sync(at: t0)
            }
            sync.cancel()
            await gate.open()

            await #expect(throws: CancellationError.self) { try await sync.value }
            #expect(FileManager.default.fileExists(atPath: directory.path) == false)
        }
    }

    /// A sync whose task is cancelled while it waits on the store — a sign-out,
    /// most of all — writes nothing to the folder.
    @Test func aCancelledSyncLeavesTheFolderAsItFoundIt() async throws {
        try await inTemporaryDirectory { parent in
            // The folder the mirror is given, not one a test made for it: what a cancelled
            // sync leaves behind includes whether there is a folder at all.
            let directory = parent.appendingPathComponent("Vault", isDirectory: true)
            let w = try await store.writer(for: hub)
            try await w.write("from the hub", to: note, continuing: store.read(), at: t0)

            let held = HeldFeedDatabase(inner: db)
            let mirror = VaultMirror(directory: directory, store: MemoryStore(database: held), device: phone)
            let sync = Task { try await mirror.sync(at: t0 + 1) }
            #expect(await eventually { await held.waiting })
            sync.cancel()
            await held.release()
            await #expect(throws: CancellationError.self) { try await sync.value }
            #expect(read("Meeting notes.md", in: directory) == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [],
                    "the folder it made is empty, and nothing of the person's was touched")
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

/// A database that lets a test act on the folder in the window the mirror is
/// reading the store in: the hook runs inside the first read of the change
/// feed, which is the first thing a sync does after its scan.
actor InterruptedFeedDatabase: RecordDatabase {
    let inner: InMemoryRecordDatabase
    private var hook: (@Sendable () -> Void)?

    init(inner: InMemoryRecordDatabase) { self.inner = inner }

    func onFirstFeedRead(_ body: @escaping @Sendable () -> Void) { hook = body }

    func save(_ records: [Record]) async throws -> [Record] { try await inner.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await inner.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await inner.query(query) }

    func records(ofType type: String) async throws -> [Record] {
        if let hook { self.hook = nil; hook() }
        return try await inner.records(ofType: type)
    }
}

/// A database that parks the first read of the change feed until it is let go,
/// so a test can do something while a sync is suspended in it.
actor HeldFeedDatabase: RecordDatabase {
    let inner: InMemoryRecordDatabase
    private var parked: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    private var released = false

    init(inner: InMemoryRecordDatabase) { self.inner = inner }

    func release() {
        released = true
        parked?.resume()
        parked = nil
    }

    func save(_ records: [Record]) async throws -> [Record] { try await inner.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await inner.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await inner.query(query) }

    func records(ofType type: String) async throws -> [Record] {
        if !released {
            waiting = true
            await withCheckedContinuation { parked = $0 }
        }
        return try await inner.records(ofType: type)
    }
}

/// A database that runs a hook inside the first query, which is what making a writer does:
/// past the sync's first cancellation fence and before any revision is written.
actor InterruptedQueryDatabase: RecordDatabase {
    let inner: InMemoryRecordDatabase
    private var hook: (@Sendable () -> Void)?

    init(inner: InMemoryRecordDatabase) { self.inner = inner }

    func onFirstQuery(_ body: @escaping @Sendable () -> Void) { hook = body }

    func save(_ records: [Record]) async throws -> [Record] { try await inner.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await inner.fetch(ids) }
    func records(ofType type: String) async throws -> [Record] { try await inner.records(ofType: type) }

    func query(_ query: RecordQuery) async throws -> [Record] {
        if let hook { self.hook = nil; hook() }
        return try await inner.query(query)
    }
}

/// Holds a coordinated write on one file until it is let go, which is what another app
/// editing that file looks like from here.
final class CoordinatedHolder: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var holding = false
    private let entered = DispatchSemaphore(value: 0)
    private let leave = DispatchSemaphore(value: 0)

    init(url: URL) { self.url = url }

    var isHolding: Bool { lock.withLock { holding } }

    func take() {
        DispatchQueue.global().async { [self] in
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { _ in
                lock.withLock { holding = true }
                entered.signal()
                leave.wait()
            }
            lock.withLock { holding = false }
        }
        entered.wait()
    }

    func release() { leave.signal() }
}

/// Holds a task at its first line until it is opened, which is how a test cancels one
/// before the work it wraps has begun. The wait is not cancellable, or a cancellation would
/// be answered here rather than by what is being tested.
actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

/// Reproductions for the adversarial review of `buddy/vault-on-the-phone`.
///
/// Every test here is written the way the suite it belongs beside is written, and every one of
/// them fails on the branch as it stands.
@Suite struct VaultMirrorReviewSweepTests {
    let db = InMemoryRecordDatabase()
    var store: MemoryStore { MemoryStore(database: db) }
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let note = VaultPath("Meeting notes.md")!

    private func inTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("topo-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    private func read(_ path: String, in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(path)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The heads a path stands at are recorded for every path the store holds, before anything
    /// is written and whether or not this folder was ever shown the text at them
    /// (`applyToDisk`, the `vault.knownPaths` line). `state.files` is conditional; `state.heads`
    /// is not, so the two halves of the baseline disagree about the same path.
    ///
    /// A write this folder refused is the case: the person's first edit after the refusal
    /// clears names a revision they were never shown as its parent, which says their edit
    /// replaces it — and it goes without ever having been read.
    @Test func aPushNeverNamesAHeadWhoseTextTheFolderWasNotShown() async throws {
        try await inTemporaryDirectory { directory in
            try await inTemporaryDirectory { elsewhere in
                let outside = elsewhere.appendingPathComponent("theirs.md")
                try Data("not ours to write".utf8).write(to: outside)
                let file = directory.appendingPathComponent("Meeting notes.md")
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)

                let w = try await store.writer(for: hub)
                try await w.write("what the hub says", to: note, continuing: store.read(), at: t0)
                let mirror = VaultMirror(directory: directory, store: store, device: phone)
                #expect(try await mirror.sync(at: t0 + 1).written.isEmpty,
                        "the link is in the way, so the folder is shown nothing")

                // The person takes the link away and writes their own file at that name. They
                // have never seen the hub's words: this folder never held them.
                try FileManager.default.removeItem(at: file)
                try Data("what I say".utf8).write(to: file)
                #expect(try await mirror.sync(at: t0 + 2).pushed == [note])

                let vault = try await store.read()
                #expect(vault.isForked(note),
                        "an edit that was never shown the hub's revision was written as its child")
                let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    .filter { $0.contains("Conflicted copy") }
                #expect(copies.count == 1, "the hub's words are nowhere in the folder")
                #expect(read("theirs.md", in: elsewhere) == "not ours to write")
            }
        }
    }

    /// The same refusal, reached the other way: bytes at that name this pass cannot read as
    /// text. Nothing is written, the heads are recorded anyway, and the person's next edit
    /// there names them.
    @Test func aPathTheWriteCouldNotReadDoesNotMakeItsHeadsSeenEither() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("what the hub says", to: note, continuing: store.read(), at: t0)
            let file = directory.appendingPathComponent("Meeting notes.md")
            try Data([0x68, 0x69, 0xFF, 0xFE]).write(to: file)

            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            #expect(try await mirror.sync(at: t0 + 1).written.isEmpty,
                    "bytes nobody can read as text are in the way, so nothing is written")

            try Data("what I say".utf8).write(to: file)
            _ = try await mirror.sync(at: t0 + 2)

            #expect(try await store.read().isForked(note),
                    "an edit that was never shown the hub's revision was written as its child")
        }
    }

    /// `rmdir` is a mutation of the person's folder, and it is made after the coordinator's
    /// unbounded wait and before the cancellation is read. A sign-out landing while another app
    /// holds that name takes the folder away when the coordinator lets the sync through.
    @Test func aSyncCancelledWhileItWaitsToTakeAwayAFolderTakesNothingAway() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("a note called notes", to: VaultPath("notes")!, continuing: store.read(), at: t0)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("notes"),
                                                    withIntermediateDirectories: true)

            let holder = CoordinatedHolder(url: directory.appendingPathComponent("notes"))
            holder.take()
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            let sync = Task { try await mirror.sync(at: t0 + 1) }
            try await Task.sleep(for: .milliseconds(300))
            sync.cancel()
            holder.release()

            await #expect(throws: CancellationError.self) { try await sync.value }
            var isFolder: ObjCBool = false
            let there = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("notes").path, isDirectory: &isFolder)
            #expect(there && isFolder.boolValue,
                    "a cancelled sync took the folder away when the coordinator let it through")
        }
    }

    /// A file this mirror wrote, whose bytes this pass cannot read as text, is left out of the
    /// scan — and the scan is what says whether a file is still there. A path in the last sync's
    /// state that the scan did not find is read as the person's deletion, so the note is deleted
    /// from the store and from every other device because of bytes on this one.
    @Test func aFileThisPassCannotReadIsNotADeletion() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("what the hub says", to: note, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            #expect(try await mirror.sync(at: t0 + 1).written == [note])

            // Somebody's editor saves it as latin-1, or a byte is flipped. The file is there,
            // it is the person's, and nobody deleted anything.
            try Data([0x68, 0x69, 0xFF, 0xFE]).write(to: directory.appendingPathComponent("Meeting notes.md"))

            let report = try await mirror.sync(at: t0 + 2)
            #expect(report.deleted.isEmpty, "a file nobody deleted was deleted from the store")
            #expect(try await store.read().text(at: note) != nil,
                    "the note is gone from every device because one device could not read it")
        }
    }

    /// The same, where the file cannot be opened at all rather than read as text — the case a
    /// permission or an I/O error makes, and the one the walk folds in with a link.
    @Test func aFileThisPassCannotOpenIsNotADeletionEither() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("what the hub says", to: note, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            #expect(try await mirror.sync(at: t0 + 1).written == [note])

            let file = directory.appendingPathComponent("Meeting notes.md")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

            let report = try await mirror.sync(at: t0 + 2)
            #expect(report.deleted.isEmpty, "a file nobody deleted was deleted from the store")
            #expect(try await store.read().text(at: note) != nil,
                    "the note is gone from every device because one device could not open it")
        }
    }

    /// The scratch name a write lands through is hidden, and hidden names are what the scan
    /// skips, so a write that did not get to its rename leaves one in the person's vault that
    /// nothing will ever take away.
    @Test func aWriteThatDidNotLandLeavesNothingBehindInTheVault() async throws {
        try await inTemporaryDirectory { directory in
            let w = try await store.writer(for: hub)
            try await w.write("from the hub", to: note, continuing: store.read(), at: t0)
            let mirror = VaultMirror(directory: directory, store: store, device: phone)
            _ = try await mirror.sync(at: t0 + 1)

            // What a process killed between the write and the rename leaves behind.
            try Data("half written".utf8).write(
                to: directory.appendingPathComponent(".topo-writing-\(UUID().uuidString)"))

            _ = try await mirror.sync(at: t0 + 2)
            let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix(".topo-writing-") }
            #expect(left.isEmpty, "the mirror's own scratch accumulates in the person's vault: \(left)")
        }
    }
}

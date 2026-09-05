import Foundation
import Testing
import TopoCore
import TopoCoreTesting

@Suite struct VaultPathTests {
    @Test func aPathIsRelativeAndHasNoHiddenComponents() {
        #expect(VaultPath("notes/Meeting notes.md")?.components == ["notes", "Meeting notes.md"])
        #expect(VaultPath("/notes/a.md") == nil)
        #expect(VaultPath("notes//a.md") == nil)
        #expect(VaultPath("../a.md") == nil)
        #expect(VaultPath("notes/../a.md") == nil)
        #expect(VaultPath(".obsidian/app.json") == nil)
        #expect(VaultPath(".topo/mirror.json") == nil)
        #expect(VaultPath("") == nil)
        #expect(VaultPath("a\u{0}b.md") == nil)
    }

    @Test func aPathIsItsOwnStringAgain() throws {
        let path = try #require(VaultPath("a/b/c.md"))
        #expect(path.string == "a/b/c.md")
        #expect(VaultPath(path.string) == path)
    }
}

@Suite struct MemoryStoreTests {
    let db = InMemoryRecordDatabase()
    var store: MemoryStore { MemoryStore(database: db) }
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let note = VaultPath("Meeting notes.md")!
    let nested = VaultPath("people/helen.md")!

    @Test func revisionsAreNamedByDeviceAndSequenceAndAreCreateOnly() async throws {
        let w = try await store.writer(for: phone)
        let first = try await w.write("one", to: note, continuing: store.read(), at: t0)
        #expect(first.ref == NoteRef(device: phone, sequence: 1))
        #expect(Note.recordID(for: first.ref).name == "note/phone/1")

        let second = try await w.write("two", to: note, continuing: store.read(), at: t0 + 1)
        #expect(second.parents == [first.ref])
        #expect(try await store.read().text(at: note) == "two")
        // The first revision is still there: nothing was overwritten.
        #expect(await db.current(Note.recordID(for: first.ref)) != nil)
        #expect(try await store.read().notes.count == 2)
    }

    @Test func aVaultIsAFolderOfFiles() async throws {
        let w = try await store.writer(for: phone)
        try await w.write("# Helen", to: nested, continuing: store.read(), at: t0)
        try await w.write("# Notes", to: note, continuing: store.read(), at: t0 + 1)
        let vault = try await store.read()
        #expect(vault.ordered.map(\.path.string) == ["Meeting notes.md", "people/helen.md"])
        #expect(vault.text(at: nested) == "# Helen")
    }

    @Test func twoDevicesEditingOnePathLeaveAConflictCopyNamedTheWayObsidianNamesOne() async throws {
        let one = try await store.writer(for: phone)
        let other = try await store.writer(for: hub)
        let empty = try await store.read()
        // Neither saw the other's write: both continue from nothing.
        try await one.write("from the phone", to: note, continuing: empty, at: t0)
        try await other.write("from the hub", to: note, continuing: empty, at: t0 + 10)

        let vault = try await store.read()
        #expect(vault.isForked(note))
        // The newer revision is the file itself.
        #expect(vault.text(at: note) == "from the hub")
        let copyPath = try #require(VaultPath("Meeting notes (Conflicted copy phone 197001121346).md"))
        let copy = try #require(vault.files[copyPath])
        #expect(copy.text == "from the phone")
        #expect(copy.isConflictCopy)
        #expect(copy.origin == note)
        #expect(vault.ordered.count == 2)
    }

    @Test func aConflictCopyNeverTakesTheNameOfARealFile() async throws {
        let one = try await store.writer(for: phone)
        let other = try await store.writer(for: hub)
        let empty = try await store.read()
        try await one.write("from the phone", to: note, continuing: empty, at: t0)
        try await other.write("from the hub", to: note, continuing: empty, at: t0 + 10)

        // Both names the copy would reach for are files the person has.
        let taken = VaultPath("Meeting notes (Conflicted copy phone 197001121346).md")!
        let alsoTaken = VaultPath("Meeting notes (Conflicted copy phone 197001121346 1).md")!
        try await other.write("a file of mine", to: taken, continuing: store.read(), at: t0 + 20)
        try await other.write("another of mine", to: alsoTaken, continuing: store.read(), at: t0 + 21)

        let vault = try await store.read()
        #expect(vault.text(at: taken) == "a file of mine")
        #expect(vault.text(at: alsoTaken) == "another of mine")
        let copy = try #require(VaultPath("Meeting notes (Conflicted copy phone 197001121346 1 2).md"))
        #expect(vault.files[copy]?.text == "from the phone")
        #expect(vault.files[copy]?.isConflictCopy == true)
    }

    @Test func aFileStandingWhereAFolderGoesIsShownBesideIt() async throws {
        let w = try await store.writer(for: phone)
        let folder = VaultPath("notes")!
        try await w.write("a note called notes", to: folder, continuing: store.read(), at: t0)
        try await w.write("today's note", to: VaultPath("notes/today.md")!, continuing: store.read(), at: t0 + 1)

        let vault = try await store.read()
        // Both revisions are kept and neither path is inside the other.
        #expect(vault.files[folder] == nil)
        #expect(vault.text(at: VaultPath("notes/today.md")!) == "today's note")
        let moved = try #require(vault.ordered.first { $0.origin == folder })
        #expect(moved.text == "a note called notes")
        #expect(moved.path == VaultPath("notes (Conflicted copy phone 197001121346)")!)
        for file in vault.ordered {
            for other in vault.ordered where other.path != file.path {
                #expect(!other.path.components.starts(with: file.path.components))
            }
        }
    }

    @Test func twoNamesThatDifferOnlyInCaseAreOneName() async throws {
        let w = try await store.writer(for: phone)
        let upper = VaultPath("Note.md")!
        let lower = VaultPath("note.md")!
        try await w.write("the first", to: upper, continuing: store.read(), at: t0)
        try await w.write("the second", to: lower, continuing: store.read(), at: t0 + 1)

        // The usual Mac disk cannot hold both, so the vault does not
        // pretend it can: the newer keeps the name and the other is beside
        // it, which is the same on every device whatever its filesystem.
        let vault = try await store.read()
        #expect(vault.text(at: lower) == "the second")
        #expect(vault.files[upper] == nil)
        let moved = try #require(vault.ordered.first { $0.origin == upper })
        #expect(moved.text == "the first")
        #expect(moved.isConflictCopy)
        let spellings = Set(vault.ordered.map { $0.path.string.lowercased() })
        #expect(spellings.count == vault.ordered.count)
    }

    @Test func aWriteThatSawTheForkResolvesIt() async throws {
        let one = try await store.writer(for: phone)
        let other = try await store.writer(for: hub)
        let empty = try await store.read()
        try await one.write("a", to: note, continuing: empty, at: t0)
        try await other.write("b", to: note, continuing: empty, at: t0 + 10)

        let forked = try await store.read()
        #expect(forked.heads(of: note).count == 2)
        let merged = try await one.write("a and b", to: note, continuing: forked, at: t0 + 20)
        #expect(Set(merged.parents) == Set(forked.heads(of: note)))

        let vault = try await store.read()
        #expect(!vault.isForked(note))
        #expect(vault.ordered.map(\.path) == [note])
        #expect(vault.text(at: note) == "a and b")
    }

    @Test func theSameTextOnTwoDevicesIsNotAConflict() async throws {
        let one = try await store.writer(for: phone)
        let other = try await store.writer(for: hub)
        let empty = try await store.read()
        try await one.write("same", to: note, continuing: empty, at: t0)
        try await other.write("same", to: note, continuing: empty, at: t0 + 10)

        let vault = try await store.read()
        #expect(vault.heads(of: note).count == 2)
        #expect(vault.ordered.map(\.path) == [note])
        #expect(vault.text(at: note) == "same")
    }

    @Test func aDeleteRemovesTheFileAndKeepsAConcurrentEditBesideIt() async throws {
        let one = try await store.writer(for: phone)
        let other = try await store.writer(for: hub)
        try await one.write("first", to: note, continuing: store.read(), at: t0)

        let seen = try await store.read()
        try await one.write("still wanted", to: note, continuing: seen, at: t0 + 5)
        try await other.delete(note, continuing: seen, at: t0 + 10)

        let vault = try await store.read()
        // The newer revision is the deletion, so the file is gone; the edit
        // it did not see is kept as a copy rather than swallowed.
        #expect(vault.files[note] == nil)
        let copy = try #require(vault.ordered.first)
        #expect(copy.isConflictCopy)
        #expect(copy.origin == note)
        #expect(copy.text == "still wanted")
    }

    @Test func aDeleteThatWonAloneLeavesNoFile() async throws {
        let w = try await store.writer(for: phone)
        try await w.write("gone soon", to: note, continuing: store.read(), at: t0)
        try await w.delete(note, continuing: store.read(), at: t0 + 1)
        let vault = try await store.read()
        #expect(vault.isEmpty)
        #expect(vault.heads(of: note).count == 1)
    }

    @Test func aLostAcknowledgementRetriedWithTheSameNonceWritesOneRevision() async throws {
        let flaky = FlakyOnceDatabase(inner: db)
        let store = MemoryStore(database: flaky)
        let w = try await store.writer(for: phone)
        let nonce = "n1"
        await #expect(throws: RecordDatabaseError.self) {
            try await w.write("only once", to: note, continuing: store.read(), at: t0, nonce: nonce)
        }
        let again = try await w.write("only once", to: note, continuing: store.read(), at: t0, nonce: nonce)
        #expect(again.ref == NoteRef(device: phone, sequence: 1))
        let vault = try await store.read()
        #expect(vault.notes.count == 1)
        #expect(vault.text(at: note) == "only once")
    }

    @Test func aRetryAfterARelaunchFindsTheRevisionItAlreadyWrote() async throws {
        let flaky = FlakyOnceDatabase(inner: db)
        let store = MemoryStore(database: flaky)
        let nonce = "n2"
        let first = try await store.writer(for: phone)
        await #expect(throws: RecordDatabaseError.self) {
            try await first.write("survives", to: note, continuing: store.read(), at: t0, nonce: nonce)
        }
        // A writer made after a relaunch knows nothing but the nonce.
        let relaunched = try await store.writer(for: phone)
        let recovered = try await relaunched.write("survives", to: note, continuing: store.read(), at: t0, nonce: nonce)
        #expect(recovered.ref == NoteRef(device: phone, sequence: 1))
        #expect(try await store.read().notes.count == 1)
    }

    @Test func aRevisionTheQueryHasNotCaughtUpWithIsReportedMissing() async throws {
        let w = try await store.writer(for: phone)
        try await w.write("one", to: note, continuing: store.read(), at: t0)
        try await w.write("two", to: note, continuing: store.read(), at: t0 + 1)

        let stale = MemoryStore(database: StaleTailDatabase(inner: db))
        let vault = try await stale.read()
        #expect(!vault.isComplete)
        #expect(vault.missing == [NoteRef(device: phone, sequence: 2)])
    }

    @Test func nothingIsWrittenFromAnIncompleteVault() async throws {
        let w = try await store.writer(for: phone)
        try await w.write("one", to: note, continuing: store.read(), at: t0)
        try await w.write("two", to: note, continuing: store.read(), at: t0 + 1)

        let stale = MemoryStore(database: StaleTailDatabase(inner: db))
        let vault = try await stale.read()
        let other = try await store.writer(for: hub)
        await #expect(throws: MemoryError.self) {
            try await other.write("three", to: note, continuing: vault, at: t0 + 2)
        }
    }

    @Test func aRecordThatDoesNotParseIsMissingRatherThanAbsent() async throws {
        _ = try await db.save(Record(type: Note.recordType, id: RecordID("note/phone/1"),
                                     fields: ["device": .string("phone")]))
        _ = try await db.save(Record(type: Note.recordType, id: RecordID("scribble")))
        let vault = try await store.read()
        #expect(vault.missing == [NoteRef(device: phone, sequence: 1)])
        #expect(vault.unreadable == [RecordID("scribble")])
        #expect(!vault.isComplete)
    }

    @Test func aRevisionRoundTripsThroughItsRecord() async throws {
        let w = try await store.writer(for: hub)
        let written = try await w.write("body", to: nested, continuing: store.read(), at: t0)
        let record = try #require(await db.current(Note.recordID(for: written.ref)))
        #expect(Note(record: record) == written)
        #expect(Note(record: Record(type: Note.recordType, id: RecordID("note/hub/9"))) == nil)
    }

    @Test func aRecordWithoutANonceReadsAsARevisionAndMatchesNoRetry() async throws {
        var old = Record(type: Note.recordType, id: RecordID("note/phone/1"), fields: [
            "device": .string("phone"), "sequence": .int(1), "path": .string(note.string),
            "text": .string("from another bundle"), "at": .date(t0),
        ])
        old.fields.removeValue(forKey: "nonce")
        _ = try await db.save(old)
        let vault = try await store.read()
        #expect(vault.isComplete)
        #expect(vault.text(at: note) == "from another bundle")
        #expect(vault.notes[NoteRef(device: phone, sequence: 1)]?.nonce == "")

        // An empty nonce is nobody's retry, so the write gets one of its own.
        let w = try await store.writer(for: phone)
        let written = try await w.write("mine", to: note, continuing: vault, at: t0 + 1, nonce: "")
        #expect(!written.nonce.isEmpty)
        #expect(written.ref == NoteRef(device: phone, sequence: 2))
    }

    @Test func theRemoteIsRecordedAndCleared() async throws {
        #expect(try await store.remote() == nil)
        try await store.setRemote(VaultRemote(url: "git@github.com:samdu/memory.git"))
        let recorded = try #require(await store.remote())
        #expect(recorded.url == "git@github.com:samdu/memory.git")
        #expect(recorded.branch == "main")
        try await store.setRemote(nil)
        #expect(try await store.remote() == nil)
    }
}

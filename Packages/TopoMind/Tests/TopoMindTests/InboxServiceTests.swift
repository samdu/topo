import Foundation
import Testing
@testable import TopoMind

/// What the sources print, what was delivered, and the time, for one service.
private final class InboxRig: @unchecked Sendable {
    let lock = NSLock()
    var prints: [String: String] = [:]
    var statuses: [String: Int32] = [:]
    var delivered: [String] = []
    var accepts = true
    var answering = true
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var minute = 12 * 60
    var runs = 0
    let root = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)", directoryHint: .isDirectory)

    init(_ document: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(document)
    }

    func write(_ document: String) throws {
        try Data(document.utf8).write(to: root.appending(path: InboxDocument.fileName))
    }

    func service() -> InboxService {
        InboxService(root: root, directory: root, environment: [:],
                     ready: { [self] in lock.withLock { answering } },
                     deliver: { [self] text in lock.withLock { if accepts { delivered.append(text) }; return accepts } },
                     run: { [self] source in
                         lock.withLock {
                             runs += 1
                             return .init(status: statuses[source.name] ?? 0, output: prints[source.name] ?? "")
                         }
                     },
                     now: { [self] in lock.withLock { clock } },
                     minuteOfDay: { [self] _ in lock.withLock { minute } })
    }

    func set(_ name: String, _ output: String) { lock.withLock { prints[name] = output } }
    func advance(_ seconds: TimeInterval) { lock.withLock { clock += seconds } }
    var told: [String] { lock.withLock { delivered } }
}

@Suite struct InboxServiceTests {
    static let two = #"{"sources":[{"name":"mail","command":"m","every":"1m"},{"name":"door","command":"d","every":"1m","urgent":true}],"flush":"10m","quiet":{"from":"23:00","to":"07:00"}}"#

    @Test func aSourcesFirstRunTellsNothingAndALaterNewLineWaitsForTheFlush() async throws {
        let rig = try InboxRig(Self.two)
        let inbox = rig.service()
        rig.set("mail", "old one\nold two")
        await inbox.tick()
        #expect(rig.told.isEmpty)
        rig.advance(61)
        rig.set("mail", "old one\nold two\nnew three")
        await inbox.tick()
        // Nothing has been flushed yet, so the first new item is told at once: the interval is since the last.
        #expect(rig.told == ["mail:\n- new three"])
        rig.advance(61)
        rig.set("mail", "old two\nnew three\nnew four")
        await inbox.tick()
        // Mutant: a line told again, or a flush before its interval.
        #expect(rig.told.count == 1)
        rig.advance(600)
        await inbox.tick()
        #expect(rig.told == ["mail:\n- new three", "mail:\n- new four"])
    }

    @Test func anUrgentItemIsToldAtOnceInQuietHoursAndAnOrdinaryOneIsNot() async throws {
        let rig = try InboxRig(Self.two)
        let inbox = rig.service()
        await inbox.tick()
        rig.lock.withLock { rig.minute = 2 * 60 }
        rig.advance(4_000)
        rig.set("mail", "a letter")
        await inbox.tick()
        #expect(rig.told.isEmpty)
        rig.advance(61)
        rig.set("door", "the doorbell")
        await inbox.tick()
        // The urgent item brings what was held with it, in the document's order.
        #expect(rig.told == ["mail:\n- a letter\n\ndoor:\n- the doorbell"])
    }

    @Test func aBatchTheMindCouldNotBeHandedIsKeptAndToldOnceAndNothingRunsWhileItIsOff() async throws {
        let rig = try InboxRig(Self.two)
        let inbox = rig.service()
        await inbox.tick()
        rig.advance(61)
        rig.set("door", "knock")
        rig.lock.withLock { rig.accepts = false }
        await inbox.tick()
        #expect(rig.told.isEmpty)
        rig.lock.withLock { rig.accepts = true; rig.answering = false }
        let runs = rig.lock.withLock { rig.runs }
        rig.advance(61)
        await inbox.tick()
        #expect(rig.lock.withLock { rig.runs } == runs)
        rig.lock.withLock { rig.answering = true }
        await inbox.tick()
        await inbox.tick()
        #expect(rig.told == ["door:\n- knock"])
        // The state on disk survives a relaunch: a new service tells nothing again.
        let again = rig.service()
        rig.advance(61)
        await again.tick()
        #expect(rig.told.count == 1)
    }

    @Test func aRefusedSourceCostsItselfAndAFailedRunTellsNothing() async throws {
        let document = InboxDocument(data: Data(#"""
        {"sources":[{"name":"ok","command":"x","every":"5m"},{"name":"bad name","command":"x","every":"5m"},
                    {"name":"fast","command":"x","every":"1s"},{"name":"ok","command":"y","every":"5m"},{"name":"none","every":"5m"}],
         "flush":"1s","quiet":{"from":"25:00","to":"07:00"}}
        """#.utf8))
        #expect(document.sources.map(\.name) == ["ok"])
        #expect(document.flush == InboxDocument.standardFlush && document.quiet == nil)
        #expect(InboxDocument(data: Data("[]".utf8)).sources.isEmpty)

        let rig = try InboxRig(Self.two)
        let inbox = rig.service()
        await inbox.tick()
        rig.advance(61)
        rig.set("door", "printed by a command that failed")
        rig.lock.withLock { rig.statuses["door"] = 1 }
        await inbox.tick()
        #expect(rig.told.isEmpty)
    }

    @Test func theShellRunsACommandAndSaysItsStatus() async {
        let ran = await InboxService.shell("printf 'a\\nb\\n'; exit 3", in: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
        #expect(ran.status == 3 && ran.output == "a\nb\n")
    }
}

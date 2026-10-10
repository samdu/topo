import CoreVideo
import Foundation
import ImageIO
import TopoTools
import XCTest

@testable import Topo

/// The screen share's kept stills (`ScreenStore`), which frames become one (`ScreenSampler`) and
/// what the mind is given of them (`ScreenTool`). The broadcast extension itself runs on no
/// simulator: what it calls is here.
final class ScreenTests: XCTestCase {
    private var root: URL!
    private var store: ScreenStore { ScreenStore(folder: root.appendingPathComponent("Screen")) }
    private var home: URL { root.appendingPathComponent("home") }
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("screen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var folderExists: Bool { FileManager.default.fileExists(atPath: store.folder.path) }

    private func refusal(_ body: () throws -> Void) -> ScreenRefusal? {
        do { try body(); return nil } catch { return error as? ScreenRefusal }
    }

    // MARK: The store

    func testNothingIsKeptWithoutADoor() throws {
        XCTAssertEqual(refusal { _ = try store.begin() }, .signedOut)
        let door = ScreenStore.Door(login: "a login")
        XCTAssertEqual(refusal { try store.keep(jpeg, at: Date(), under: door) }, .signedOut)
        XCTAssertFalse(store.beat(at: Date(), since: Date(), under: door))
        store.end()
        XCTAssertFalse(folderExists, "the extension's side made the folder")
        XCTAssertNil(store.live())
        XCTAssertEqual(store.stills(), [])
    }

    func testABroadcastKeepsStillsOldestFirstAndHoldsTheNewestOfTheRing() throws {
        try store.open()
        let began = Date(timeIntervalSince1970: 1_000_000)
        let door = try store.begin(at: began)
        XCTAssertEqual(store.live(now: began)?.since, began)
        for index in 0..<(ScreenStore.ring + 5) {
            try store.keep(jpeg, at: began.addingTimeInterval(Double(index) * 1.5), under: door)
        }
        let stills = store.stills()
        XCTAssertEqual(stills.count, ScreenStore.ring)
        XCTAssertEqual(stills.first?.time, began.addingTimeInterval(5 * 1.5))
        XCTAssertEqual(stills.last?.time, began.addingTimeInterval(Double(ScreenStore.ring + 4) * 1.5))
        XCTAssertEqual(stills.map(\.time), stills.map(\.time).sorted())
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(stills.last).url), jpeg)
    }

    func testABroadcastIsLiveWhileItsExtensionSeesFramesAndItsStillsOutliveIt() throws {
        try store.open()
        let began = Date(timeIntervalSince1970: 1_000_000)
        let door = try store.begin(at: began)
        try store.keep(jpeg, at: began, under: door)
        XCTAssertNotNil(store.live(now: began.addingTimeInterval(ScreenStore.stale - 1)))
        XCTAssertNil(store.live(now: began.addingTimeInterval(ScreenStore.stale)), "a broadcast whose extension went quiet is still live")
        XCTAssertTrue(store.beat(at: began.addingTimeInterval(60), since: began, under: door))
        XCTAssertEqual(store.live(now: began.addingTimeInterval(61))?.since, began)
        store.end()
        XCTAssertNil(store.live(now: began.addingTimeInterval(61)))
        XCTAssertEqual(store.stills().count, 1)

        // The next broadcast begins with none of the last one's.
        _ = try store.begin(at: began.addingTimeInterval(120))
        XCTAssertEqual(store.stills(), [])
    }

    func testASignOutEndsTheBroadcastAndTakesTheStills() throws {
        try store.open()
        let door = try store.begin()
        try store.keep(jpeg, at: Date(), under: door)
        store.close()
        XCTAssertFalse(folderExists)
        XCTAssertEqual(refusal { try store.keep(jpeg, at: Date(), under: door) }, .signedOut)
        XCTAssertFalse(store.beat(at: Date(), since: Date(), under: door))
        XCTAssertFalse(folderExists, "a frame after the sign-out brought the folder back")

        // The next login's door is another: the broadcast still running under the last keeps nothing.
        try store.open()
        XCTAssertNotEqual(store.door(), door)
        XCTAssertEqual(refusal { try store.keep(jpeg, at: Date(), under: door) }, .signedOut)
        XCTAssertFalse(store.beat(at: Date(), since: Date(), under: door))
        XCTAssertNil(store.live())
        XCTAssertEqual(store.stills(), [])
    }

    /// A still written between the old door's last check and the new login's opening carries the
    /// old login's name, and is no still of the new one.
    func testAStillOfAnotherLoginIsNoStill() throws {
        try store.open()
        try jpeg.write(to: store.folder.appendingPathComponent(ScreenStore.name(login: "an earlier login", at: Date())))
        try jpeg.write(to: store.folder.appendingPathComponent("notes.jpg"))
        XCTAssertEqual(store.stills(), [])
        let door = try store.begin()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folder.path).filter { $0.hasSuffix(".jpg") }, [])
        try store.keep(jpeg, at: Date(), under: door)
        XCTAssertEqual(store.stills().count, 1)
    }

    func testTheDoorFollowsTheOwnerAndKeepsItsLoginWhileOpen() throws {
        store.follow(owner: true)
        let door = try XCTUnwrap(store.door())
        store.follow(owner: true)
        XCTAssertEqual(store.door(), door)
        XCTAssertEqual(try store.folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        store.follow(owner: false)
        XCTAssertFalse(folderExists)
        store.follow(owner: false)
        XCTAssertFalse(folderExists)
    }

    func testAStillsNameIsItsLoginAndItsTime() {
        let time = Date(timeIntervalSince1970: 1_760_000_000.123)
        let name = ScreenStore.name(login: "login", at: time)
        XCTAssertEqual(name, "login-1760000000123.jpg")
        XCTAssertEqual(try XCTUnwrap(ScreenStore.time(of: name, login: "login")).timeIntervalSince1970, 1_760_000_000.123, accuracy: 0.0005)
        for other in ["other-1760000000123.jpg", "login-1760000000123.png", "login-abc.jpg", "login--5.jpg", "login-.jpg", "_open.json"] {
            XCTAssertNil(ScreenStore.time(of: other, login: "login"), other)
        }
    }

    /// The sign-out that lands between the extension's reading of the door and its still: the
    /// door goes first, so the still that finds none on looking again takes itself away.
    func testAStillLandingAsTheDoorGoesDoesNotStay() throws {
        try store.open()
        let door = try store.begin()
        XCTAssertTrue(try store.keep(jpeg, at: Date(timeIntervalSince1970: 1), under: door))
        try FileManager.default.removeItem(at: store.folder.appendingPathComponent("_open.json"))
        XCTAssertEqual(refusal { try store.keep(jpeg, at: Date(timeIntervalSince1970: 2), under: door) }, .signedOut)
        // The same with the door gone only after the still had its name.
        try FileManager.default.createDirectory(at: store.folder.appendingPathComponent(ScreenStore.name(login: door.login, at: Date(timeIntervalSince1970: 3))), withIntermediateDirectories: false)
        try JSONEncoder().encode(door).write(to: store.folder.appendingPathComponent("_open.json"))
        XCTAssertFalse(try store.keep(jpeg, at: Date(timeIntervalSince1970: 3), under: door), "a still that could not take its name was counted as kept")
        let names = try FileManager.default.contentsOfDirectory(atPath: store.folder.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".part") }, [], "a still that was not kept left its bytes behind")
        store.close()
        XCTAssertFalse(folderExists)
    }

    /// The sign-out that lands after the still has its name: the door is read once more, and the
    /// still that finds it gone takes itself away.
    func testAStillNamedAsTheDoorGoesIsTakenAway() throws {
        try store.open()
        let door = try store.begin()
        let open = store.folder.appendingPathComponent("_open.json")
        let landed = { try? FileManager.default.removeItem(at: open) }
        XCTAssertEqual(refusal { try store.keep(jpeg, at: Date(timeIntervalSince1970: 1), under: door, landed: { _ = landed() }) }, .signedOut)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folder.path).filter { $0 != "_live.json" }, [],
                       "a still that landed as the door went stayed")
        // The same with the door opened again meanwhile, which is another door.
        try store.open()
        let next = try store.begin()
        let store = store
        XCTAssertEqual(refusal { try store.keep(jpeg, at: Date(timeIntervalSince1970: 2), under: next, landed: { store.close(); try? store.open() }) },
                       .signedOut)
        XCTAssertEqual(store.stills().count, 0)
    }

    func testAKeptStillLeavesNothingButItself() throws {
        try store.open()
        let door = try store.begin()
        XCTAssertTrue(try store.keep(jpeg, at: Date(), under: door))
        let names = try FileManager.default.contentsOfDirectory(atPath: store.folder.path).sorted()
        XCTAssertEqual(names.count, 3, "\(names)")
        XCTAssertEqual(names.filter { $0.hasSuffix(".jpg") }.count, 1)
    }

    // MARK: The sampler

    /// A BGRA frame of one grey, with a patch of another where asked.
    private func frame(width: Int = 400, height: Int = 800, grey: UInt8 = 200, patch: CGRect? = nil, patchGrey: UInt8 = 0,
                       format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attributes, &made), kCVReturnSuccess)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let planar = format != kCVPixelFormatType_32BGRA
        let base = try XCTUnwrap(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let row = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let step = planar ? 1 : 4
        for y in 0..<height {
            for x in 0..<width {
                let value = patch?.contains(CGPoint(x: x, y: y)) == true ? patchGrey : grey
                for byte in 0..<step { base[y * row + x * step + byte] = byte == 3 ? 255 : value }
            }
        }
        if planar, let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        }
        return buffer
    }

    /// Paints a patch of a BGRA frame one colour, or of a planar frame's chroma one pair of values,
    /// leaving its luma as it was.
    private func paint(_ buffer: CVPixelBuffer, _ patch: CGRect, _ bytes: [UInt8]) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let planar = CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA
        let base = try XCTUnwrap(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 1) : CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let row = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) : CVPixelBufferGetBytesPerRow(buffer)
        let scale = planar ? 2 : 1, size = planar ? 2 : 4
        for y in Int(patch.minY) / scale..<Int(patch.maxY) / scale {
            for x in Int(patch.minX) / scale..<Int(patch.maxX) / scale {
                for (index, byte) in bytes.enumerated() { base[y * row + x * size + index] = byte }
            }
        }
    }

    private func size(of jpeg: Data) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    /// Takes the frame and counts it kept, as the extension does once its still is on disk.
    private func keep(_ frame: CVPixelBuffer, in sampler: inout ScreenSampler, at time: Date) -> Data? {
        guard let taken = sampler.take(frame, at: time) else { return nil }
        sampler.kept(taken, at: time)
        return taken.jpeg
    }

    func testAStillIsKeptOnlyWhenTheScreenChangedAndNoSoonerThanTheInterval() throws {
        var sampler = ScreenSampler()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let plain = try frame()
        let first = try XCTUnwrap(keep(plain, in: &sampler, at: start))
        XCTAssertEqual(try size(of: first), CGSize(width: 400, height: 800))
        // One typed character's worth: a 10 by 16 patch.
        let typed = try frame(patch: CGRect(x: 120, y: 300, width: 10, height: 16))
        XCTAssertTrue(sampler.early(at: start.addingTimeInterval(ScreenSampler.interval - 0.1)))
        XCTAssertNil(keep(typed, in: &sampler, at: start.addingTimeInterval(ScreenSampler.interval - 0.1)), "a still was kept inside the interval")
        XCTAssertFalse(sampler.early(at: start.addingTimeInterval(ScreenSampler.interval)))
        XCTAssertNil(keep(plain, in: &sampler, at: start.addingTimeInterval(10)), "a screen that had not changed was kept again")
        XCTAssertNil(keep(try frame(), in: &sampler, at: start.addingTimeInterval(20)))
        XCTAssertNotNil(keep(typed, in: &sampler, at: start.addingTimeInterval(30)), "a changed screen was not kept")
        XCTAssertNil(keep(typed, in: &sampler, at: start.addingTimeInterval(40)))
        // The interval counts from the last kept, not the last seen.
        XCTAssertNotNil(keep(plain, in: &sampler, at: start.addingTimeInterval(30 + ScreenSampler.interval)))
    }

    /// A frame whose write was dropped (the phone locked) is no still, so the same screen offered
    /// again is taken again, and at once.
    func testAFrameThatWasNotKeptIsTakenAgain() throws {
        var sampler = ScreenSampler()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNotNil(keep(try frame(), in: &sampler, at: start))
        let typed = try frame(patch: CGRect(x: 120, y: 300, width: 10, height: 16))
        XCTAssertNotNil(sampler.take(typed, at: start.addingTimeInterval(10)))
        XCTAssertFalse(sampler.early(at: start.addingTimeInterval(10.1)))
        XCTAssertNotNil(keep(typed, in: &sampler, at: start.addingTimeInterval(10.1)), "a frame dropped at the write was never offered a second time")
        XCTAssertNil(keep(typed, in: &sampler, at: start.addingTimeInterval(20)))
    }

    func testAStillIsNoLargerThanItsLongSideAndTurnedAsTheScreenWasHeld() throws {
        let sampler = ScreenSampler()
        let large = try frame(width: 1200, height: 2600)
        let still = try size(of: try XCTUnwrap(sampler.take(large, at: Date(timeIntervalSince1970: 0))).jpeg)
        XCTAssertEqual(max(still.width, still.height), ScreenSampler.longSide, accuracy: 1)
        XCTAssertEqual(still.width / still.height, 1200.0 / 2600.0, accuracy: 0.01)

        let turned = ScreenSampler()
        let sideways = try size(of: try XCTUnwrap(turned.take(try frame(), orientation: .right, at: Date(timeIntervalSince1970: 0))).jpeg)
        XCTAssertEqual(sideways, CGSize(width: 800, height: 400))
    }

    /// A change of colour alone is a change: a patch gone from red to blue at the same green, and
    /// the same in a planar frame, where the luma does not move at all.
    func testAChangeOfColourAloneIsAChange() throws {
        let patch = CGRect(x: 120, y: 300, width: 40, height: 40)
        let red = try frame(), blue = try frame()
        try paint(red, patch, [0, 90, 255])
        try paint(blue, patch, [255, 90, 0])
        var sampler = ScreenSampler()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNotNil(keep(red, in: &sampler, at: start))
        XCTAssertNil(keep(red, in: &sampler, at: start.addingTimeInterval(10)))
        XCTAssertNotNil(keep(blue, in: &sampler, at: start.addingTimeInterval(20)), "a patch gone from red to blue was not a change")

        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            let one = try frame(format: format), other = try frame(format: format)
            try paint(one, patch, [90, 240])
            try paint(other, patch, [240, 110])
            let before = try XCTUnwrap(ScreenSampler.mark(of: one)), after = try XCTUnwrap(ScreenSampler.mark(of: other))
            let cells = ScreenSampler.grid * ScreenSampler.grid
            XCTAssertEqual(Array(before.prefix(cells)), Array(after.prefix(cells)), "the luma moved, so this shows nothing of the chroma")
            XCTAssertTrue(ScreenSampler.changed(from: before, to: after), "a patch whose colour alone changed was not a change")
        }
    }

    func testTheFramesReplayKitHandsOverAreJudgedByEveryChannel() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            let plain = try XCTUnwrap(ScreenSampler.mark(of: try frame(format: format)))
            let cells = ScreenSampler.grid * ScreenSampler.grid
            XCTAssertEqual(plain.count, cells * 3)
            XCTAssertTrue(plain.prefix(cells).allSatisfy { abs($0 - 200) < 0.001 })
            XCTAssertTrue(plain.suffix(cells * 2).allSatisfy { abs($0 - 128) < 0.001 })
            let typed = try XCTUnwrap(ScreenSampler.mark(of: try frame(patch: CGRect(x: 120, y: 300, width: 10, height: 16), format: format)))
            XCTAssertTrue(ScreenSampler.changed(from: plain, to: typed))
            XCTAssertFalse(ScreenSampler.changed(from: plain, to: plain))
            let sampler = ScreenSampler()
            XCTAssertNotNil(sampler.take(try frame(format: format), at: Date(timeIntervalSince1970: 0)))
        }
        XCTAssertNil(ScreenSampler.mark(of: try frame(format: kCVPixelFormatType_32ARGB)))
    }

    // MARK: The watch

    /// What the extension does with a frame that arrives inside the interval and is followed by
    /// none: the tick past the interval judges it, so the screen as it came to rest is kept.
    func testTheLastFrameInsideTheIntervalIsKeptAtTheTickPastIt() throws {
        try store.open()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let door = try store.begin(at: start)
        var watch = ScreenWatch(store: store, door: door, since: start)
        let typed = try frame(patch: CGRect(x: 120, y: 300, width: 10, height: 16))
        let more = try frame(patch: CGRect(x: 120, y: 300, width: 40, height: 16))
        XCTAssertNil(watch.frame(try frame(), orientation: .up, at: start))
        XCTAssertEqual(store.stills().count, 1)
        // Two frames inside the interval, and then the screen rests.
        XCTAssertNil(watch.frame(typed, orientation: .up, at: start.addingTimeInterval(0.4)))
        XCTAssertNil(watch.frame(more, orientation: .up, at: start.addingTimeInterval(0.8)))
        XCTAssertEqual(store.stills().count, 1, "a still was kept inside the interval")
        XCTAssertNil(watch.tick(at: start.addingTimeInterval(1)))
        XCTAssertEqual(store.stills().count, 1, "a tick inside the interval kept the frame held")
        let rest = start.addingTimeInterval(ScreenSampler.interval + 0.1)
        XCTAssertNil(watch.tick(at: rest))
        XCTAssertEqual(store.stills().map(\.time.timeIntervalSince1970), [start.timeIntervalSince1970, rest.timeIntervalSince1970],
                       "the frame the screen came to rest on was never kept")
        var judge = ScreenSampler()
        _ = keep(more, in: &judge, at: start)
        XCTAssertNil(judge.take(more, at: start.addingTimeInterval(10)))
        // It is held once: the ticks after keep nothing more, and each marks the broadcast live.
        XCTAssertNil(watch.tick(at: rest.addingTimeInterval(5)))
        XCTAssertEqual(store.stills().count, 2)
        XCTAssertEqual(store.live(now: rest.addingTimeInterval(6))?.beat, rest.addingTimeInterval(5))
        // A frame past the interval is judged as it arrives and leaves none held.
        XCTAssertNil(watch.frame(try frame(), orientation: .up, at: rest.addingTimeInterval(10)))
        XCTAssertEqual(store.stills().count, 3)
        XCTAssertNil(watch.tick(at: rest.addingTimeInterval(20)))
        XCTAssertEqual(store.stills().count, 3)
    }

    /// A share of a resting screen ends at the tick after the door goes, and a frame after it is refused.
    func testATickOrAFrameAfterTheDoorGoesEndsTheBroadcast() throws {
        try store.open()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let door = try store.begin(at: start)
        var watch = ScreenWatch(store: store, door: door, since: start)
        XCTAssertNil(watch.tick(at: start.addingTimeInterval(2)))
        store.close()
        XCTAssertEqual(watch.tick(at: start.addingTimeInterval(4)), .signedOut)
        XCTAssertEqual(watch.frame(try frame(), orientation: .up, at: start.addingTimeInterval(5)), .signedOut)
        XCTAssertFalse(folderExists)
    }

    // MARK: The tool

    private func tool(now: Date = Date()) -> ScreenTool {
        let store = store, home = home
        return ScreenTool(store: { store }, home: { home }, now: { now })
    }

    func testTheToolTakesStatusAndLookAndNothingElse() throws {
        let tool = tool()
        XCTAssertEqual(try tool.parse(["status"]), .status)
        XCTAssertEqual(try tool.parse(["look"]), .look(last: 1))
        XCTAssertEqual(try tool.parse(["look", "--last", "6"]), .look(last: 6))
        for bad in [[], ["start"], ["stop"], ["status", "x"], ["look", "--last"], ["look", "--last", "0"], ["look", "--last", "7"],
                    ["look", "--last", "two"], ["look", "3"]] {
            XCTAssertThrowsError(try tool.parse(bad), "\(bad)")
        }
    }

    func testNothingSharedIsSaidAsThatAndNeverAsAnEmptyAnswer() async throws {
        for call in [["status"], ["look"]] {
            let signedOut = await tool().run(call)
            XCTAssertEqual(signedOut.status, ToolReply.failed)
            XCTAssertTrue(signedOut.text.contains("not being shared"), signedOut.text)
        }
        try store.open()
        for call in [["status"], ["look"]] {
            let unshared = await tool().run(call)
            XCTAssertEqual(unshared.status, ToolReply.failed)
            XCTAssertTrue(unshared.text.contains("Only the person can share it"), unshared.text)
        }
        let began = Date(timeIntervalSince1970: 1_000_000)
        _ = try store.begin(at: began)
        let early = await tool(now: began.addingTimeInterval(1)).run(["look"])
        XCTAssertEqual(early.status, ToolReply.failed)
        XCTAssertTrue(early.text.contains("no still is kept yet"), early.text)
        let status = await tool(now: began.addingTimeInterval(1)).run(["status"])
        XCTAssertEqual(status.status, ToolReply.ok)
        XCTAssertTrue(status.text.hasPrefix("sharing since "), status.text)
        XCTAssertTrue(status.text.contains("0 stills"), status.text)
    }

    func testLookCopiesTheNewestStillsIntoTheHomeAndTheCopiesGoWithTheLogin() async throws {
        try store.open()
        let began = Date(timeIntervalSince1970: 1_760_000_000)
        let door = try store.begin(at: began)
        for index in 0..<4 {
            try store.keep(jpeg + Data([UInt8(index)]), at: began.addingTimeInterval(Double(index) * 2), under: door)
        }
        let now = began.addingTimeInterval(10)
        let one = await tool(now: now).run(["look"])
        XCTAssertEqual(one.status, ToolReply.ok, one.text)
        let lines = one.text.split(separator: "\n").map(String.init)
        guard lines.count == 2 else { return XCTFail(one.text) }
        XCTAssertTrue(lines[0].contains("4 stills") && lines[0].contains("newest 4 s ago"), lines[0])
        let newest = ScreenTool.name(of: began.addingTimeInterval(6))
        XCTAssertEqual(newest, "20251009T085326.000Z.jpg")
        XCTAssertTrue(lines[1].hasPrefix("/home/topo/screen/\(newest) | "), lines[1])
        XCTAssertTrue(lines[1].hasSuffix(" | 4 s ago"), lines[1])
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("screen/\(newest)")), jpeg + Data([3]))

        // The same still again, and the two before it: one file each, none taken away.
        let three = await tool(now: now).run(["look", "--last", "3"])
        XCTAssertEqual(three.status, ToolReply.ok, three.text)
        XCTAssertEqual(three.text.split(separator: "\n").count, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("screen").path).count, 3)
        XCTAssertEqual(store.stills().count, 4, "looking took a still out of the ring")

        // After the share ends the stills are still there to look at, and the answer says so.
        store.end()
        let after = await tool(now: now).run(["look"])
        XCTAssertEqual(after.status, ToolReply.ok)
        XCTAssertTrue(after.text.hasPrefix("not sharing now; the stills are from the last share"), after.text)

        // A copy lasts ten minutes: a look after that takes it away and makes the one asked for.
        let copies = home.appendingPathComponent("screen")
        let old = copies.appendingPathComponent(ScreenTool.name(of: began))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path) == false)
        _ = await tool(now: now).run(["look", "--last", "4"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ScreenTool.copiesLast - 60)], ofItemAtPath: old.path)
        _ = await tool(now: now).run(["look"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "a copy outlasted its ten minutes")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copies.path).count, 3)

        // Signed out, or no longer the guest's phone: the stills and every copy go.
        ScreenTool.follow(owner: false, store: store, home: home)
        XCTAssertFalse(folderExists)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copies.path), [], "a copy of the person's screen outlived the login")
        let gone = await tool(now: now).run(["look"])
        XCTAssertEqual(gone.status, ToolReply.failed)
        ScreenTool.follow(owner: true, store: store, home: home)
        XCTAssertNotNil(store.door())
    }

    /// The sign-out or demotion that runs while a `look` is making its copies: the door is shut
    /// and the copies taken away before the look's own lands, and the look takes it away itself.
    func testACopyMadeAcrossASignOutDoesNotStay() async throws {
        try store.open()
        let began = Date(timeIntervalSince1970: 1_760_000_000)
        let door = try store.begin(at: began)
        try store.keep(jpeg, at: began, under: door)
        let store = store, home = home
        let across = ScreenTool(store: { store }, home: { home }, now: { began }, copied: {
            ScreenTool.follow(owner: false, store: store, home: home)
            // The copy this look had already made lands after the sweep, as a slower write would.
            try? Data([1]).write(to: home.appendingPathComponent("screen/\(ScreenTool.name(of: began))"))
        })
        let reply = await across.run(["look"])
        XCTAssertEqual(reply.status, ToolReply.failed)
        XCTAssertTrue(reply.text.contains("not being shared"), reply.text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("screen").path), [],
                       "a copy of the person's screen made across a sign-out stayed")
    }

    /// A copy goes when its time is up with no later `look`, and one whose time ran out while
    /// Topo was suspended goes at the sweep it makes on coming to the front.
    func testACopyGoesWhenItsTimeIsUpWithNoLaterLook() async throws {
        try store.open()
        let began = Date(timeIntervalSince1970: 1_760_000_000)
        let door = try store.begin(at: began)
        try store.keep(jpeg, at: began, under: door)
        let store = store, home = home
        let copy = home.appendingPathComponent("screen/\(ScreenTool.name(of: began))")
        let brief = ScreenTool(store: { store }, home: { home }, now: { began }, lasts: 1)
        let reply = await brief.run(["look"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        let clock = ContinuousClock(), deadline = clock.now + .seconds(10)
        while FileManager.default.fileExists(atPath: copy.path), clock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "a copy outlasted its time with no later look")

        _ = await tool(now: began).run(["look"])
        ScreenTool.sweep(under: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "a copy inside its ten minutes was swept")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ScreenTool.copiesLast - 60)], ofItemAtPath: copy.path)
        ScreenTool.sweep(under: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "a copy past its ten minutes outlasted the sweep")
    }

    func testLookWritesOverNothingOfTheGuests() async throws {
        try store.open()
        let began = Date(timeIntervalSince1970: 1_760_000_000)
        let door = try store.begin(at: began)
        try store.keep(jpeg, at: began, under: door)
        let folder = home.appendingPathComponent("screen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let theirs = Data("the guest's own".utf8)
        try theirs.write(to: folder.appendingPathComponent(ScreenTool.name(of: began)))
        let reply = await tool(now: began).run(["look"])
        XCTAssertEqual(reply.status, ToolReply.ok)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(ScreenTool.name(of: began))), theirs)
    }
}

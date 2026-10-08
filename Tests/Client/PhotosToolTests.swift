import Foundation
import ImageIO
import Photos
import TopoTools
import UIKit
import XCTest

@testable import Topo

/// Photos access standing where the test puts it, counting its prompts.
private final class PhotosPermission: Authorizer, @unchecked Sendable {
    let name = "Photos"
    private let lock = NSLock()
    private var standing: Access
    private let answer: Bool
    private var _prompts = 0

    init(_ standing: Access = .granted, answer: Bool = true) {
        self.standing = standing
        self.answer = answer
    }

    var prompts: Int { lock.withLock { _prompts } }
    func access() async -> Access { lock.withLock { standing } }
    func request() async -> Bool {
        lock.withLock {
            _prompts += 1
            standing = answer ? .granted : .denied
        }
        return answer
    }
}

private final class Library: PhotoLibrary, @unchecked Sendable {
    private let lock = NSLock()
    var isLimited = false
    var albumList: [PhotoAlbum] = []
    var records: [PhotoRecord] = []
    var stills: [String: Data] = [:]
    private var _queries: [PhotoQuery] = []
    private var _added: [Data] = []

    var queries: [PhotoQuery] { lock.withLock { _queries } }
    var added: [Data] { lock.withLock { _added } }

    func limited() async -> Bool { isLimited }
    func albums() async throws -> [PhotoAlbum] { albumList }
    func search(_ query: PhotoQuery) async throws -> [PhotoRecord] {
        lock.withLock { _queries.append(query) }
        return Array(records.prefix(query.limit + 1))
    }
    func still(id: String, longSide: Int) async throws -> (record: PhotoRecord, jpeg: Data)? {
        guard let jpeg = stills[id], let record = records.first(where: { $0.id == id }) else { return nil }
        return (record, jpeg)
    }
    func add(image: Data) async throws -> String {
        lock.withLock { _added.append(image) }
        return "NEW-1/L0/001"
    }
}

final class PhotosToolTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("photos-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func tool(_ library: Library = Library(), _ permission: PhotosPermission = PhotosPermission(),
                      read: @escaping @Sendable (String) async -> Data? = { _ in nil }) -> PhotosTool {
        let home = home!
        return PhotosTool(library: library, authorizer: permission, broker: PermissionBroker(), home: { home }, read: read)
    }

    private static func picture(_ type: String = "public.png", side: Int = 8) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return type == "public.png" ? image.pngData()! : image.jpegData(compressionQuality: 0.8)!
    }

    private static let photo = PhotoRecord(id: "AAAA1111-2222/L0/001", taken: Date(timeIntervalSince1970: 1_780_000_000), kind: "photo",
                                           width: 4032, height: 3024, favorite: true, latitude: 37.7749, longitude: -122.4194)

    // MARK: The calls

    func testTheCallsItTakes() throws {
        let tool = tool()
        XCTAssertEqual(try tool.parse(["albums"]), .albums)
        XCTAssertEqual(try tool.parse(["export", "A/L0/001"]), .export(id: "A/L0/001"))
        XCTAssertEqual(try tool.parse(["save", "/home/topo/a.png"]), .save(path: "/home/topo/a.png"))
        XCTAssertEqual(try tool.parse(["search"]), .search(PhotoQuery()))
        var query = PhotoQuery(album: "ALBUM", favorites: true)
        query.kind = .video
        query.limit = 5
        XCTAssertEqual(try tool.parse(["search", "--album", "ALBUM", "--kind", "video", "--favorites", "--limit", "5"]), .search(query))
    }

    /// A `--to` naming a day is the whole of that day; one naming a time is that moment.
    func testADayIsTheWholeOfIt() throws {
        let tool = tool()
        guard case let .search(day) = try tool.parse(["search", "--from", "2026-09-27", "--to", "2026-09-27"]),
              case let .search(moment) = try tool.parse(["search", "--to", "2026-09-27T14:30"]) else { return XCTFail("not a search") }
        XCTAssertEqual(day.from, ToolDates.read("2026-09-27")?.date)
        XCTAssertEqual(day.to, ToolDates.read("2026-09-28")?.date)
        XCTAssertEqual(moment.to, ToolDates.read("2026-09-27T14:30")?.date)
    }

    /// A call the tool does not take is answered with its usage, and asks the person nothing.
    func testAMisuseAsksNothing() async {
        let permission = PhotosPermission(.undetermined)
        let tool = tool(Library(), permission)
        for call in [[], ["delete", "A"], ["search", "dog"], ["search", "--kind", "panorama"], ["search", "--limit", "0"],
                     ["search", "--limit", "51"], ["search", "--from", "2026-09-28", "--to", "2026-09-27"],
                     ["albums", "--favorites"], ["export"], ["export", "A", "--limit", "3"], ["save"], ["search", "--colour", "red"]] {
            let reply = await tool.run(call)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(call): \(reply.text)")
            XCTAssertTrue(reply.text.contains("topo photos albums"), "\(call) is not answered with the usage")
        }
        XCTAssertEqual(permission.prompts, 0)
        let words = await tool.run(["search", "dog"])
        XCTAssertTrue(words.text.contains("not by what a photo shows"), words.text)
    }

    // MARK: The permission

    func testTheFirstCallAsksAndARefusalSaysWhere() async {
        let asked = PhotosPermission(.undetermined)
        let library = Library()
        library.albumList = [PhotoAlbum(id: "A", title: "Trips", count: 2)]
        let allowed = await tool(library, asked).run(["albums"])
        XCTAssertEqual(allowed, .ok("A | Trips | 2 items\n"))
        XCTAssertEqual(asked.prompts, 1)

        let refused = PhotosPermission(.undetermined, answer: false)
        for call in [["albums"], ["search"], ["export", "A"], ["save", "/home/topo/a.png"]] {
            let reply = await tool(library, refused).run(call)
            XCTAssertEqual(reply.status, ToolReply.denied, "\(call)")
            XCTAssertTrue(reply.text.contains("Apps › Topo › Photos"), reply.text)
        }
        XCTAssertEqual(refused.prompts, 1)
        XCTAssertTrue(library.added.isEmpty)
    }

    // MARK: Reading

    func testAlbumsAndALimitedLibrarySaysSo() async {
        let library = Library()
        library.albumList = [PhotoAlbum(id: "S/1", title: "Screenshots", count: 1), PhotoAlbum(id: "A/2", title: "Lake\nTrip", count: 12)]
        let whole = await tool(library).run(["albums"])
        XCTAssertEqual(whole, .ok("S/1 | Screenshots | 1 item\nA/2 | Lake Trip | 12 items\n"))
        library.isLimited = true
        let limited = await tool(library).run(["albums"])
        XCTAssertTrue(limited.text.hasPrefix("limited access: only the photos the person chose"), limited.text)
        XCTAssertTrue(limited.text.hasSuffix("A/2 | Lake Trip | 12 items\n"), limited.text)
        library.albumList = []
        let none = await tool(library).run(["search"])
        XCTAssertTrue(none.text.hasSuffix("no photos found\n") && none.text.hasPrefix("limited access"), none.text)
    }

    func testASearchPrintsOneALineAndSaysWhenThereAreMore() async {
        let library = Library()
        library.records = [Self.photo] + (0..<25).map {
            PhotoRecord(id: "V\($0)/L0/001", taken: nil, kind: "video", width: 1920, height: 1080)
        }
        let reply = await tool(library).run(["search", "--limit", "2"])
        XCTAssertEqual(reply.status, ToolReply.ok)
        let lines = reply.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "AAAA1111-2222/L0/001 | \(ToolDates.write(Self.photo.taken!)) | photo | 4032×3024 | favourite | 37.77490,-122.41940")
        XCTAssertEqual(lines[1], "V0/L0/001 | video | 1920×1080")
        XCTAssertEqual(lines[2], "… and more; narrow the dates or raise --limit (at most 50)")
        XCTAssertEqual(library.queries.last?.limit, 2)

        library.records = [Self.photo]
        let all = await tool(library).run(["search"])
        XCTAssertEqual(all.text.split(separator: "\n").count, 1)
        XCTAssertEqual(library.queries.last?.limit, PhotosTool.shown)
    }

    // MARK: Export

    func testAnExportLandsUnderTheHomeAndIsNeverWrittenOver() async throws {
        let library = Library()
        library.records = [Self.photo]
        library.stills = [Self.photo.id: Self.picture("public.jpeg")]
        let tool = tool(library)
        let reply = await tool.run(["export", Self.photo.id])
        XCTAssertEqual(reply, .ok("exported: /home/topo/photos/AAAA1111-2222.jpg\n"))
        let file = home.appendingPathComponent("photos/AAAA1111-2222.jpg")
        XCTAssertEqual(try Data(contentsOf: file), library.stills[Self.photo.id])

        library.stills[Self.photo.id] = Self.picture("public.jpeg", side: 16)
        let again = await tool.run(["export", Self.photo.id])
        XCTAssertEqual(again.status, ToolReply.ok)
        XCTAssertTrue(again.text.hasPrefix("already exported: /home/topo/photos/AAAA1111-2222.jpg\n"), again.text)
        XCTAssertEqual(try Data(contentsOf: file), Self.picture("public.jpeg"), "the first export was written over")
    }

    func testAnExportOfAVideoSaysItIsAStillAndOfNothingFails() async {
        let library = Library()
        library.records = [PhotoRecord(id: "VID/L0/001", taken: nil, kind: "video", width: 1920, height: 1080)]
        library.stills = ["VID/L0/001": Self.picture("public.jpeg")]
        let video = await tool(library).run(["export", "VID/L0/001"])
        XCTAssertEqual(video, .ok("exported: /home/topo/photos/VID.jpg (a video: this is a still of it)\n"))
        let missing = await tool(library).run(["export", "GONE/L0/001"])
        XCTAssertEqual(missing, .failed("topo: no photo with the id GONE/L0/001\n"))
        for id in ["../../etc", "/", "..", "é"] {
            let reply = await tool(library).run(["export", id])
            XCTAssertEqual(reply.status, ToolReply.usage, "\(id): \(reply.text)")
        }
        XCTAssertEqual(try? PhotosTool.fileName(for: "a/../../b"), "a.jpg")
    }

    /// A link the guest put where the export folder goes sends the app's write nowhere.
    func testAnExportThroughALinkIsRefused() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("photos-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("photos"), withDestinationURL: outside)
        let library = Library()
        library.records = [Self.photo]
        library.stills = [Self.photo.id: Self.picture("public.jpeg")]
        let reply = await tool(library).run(["export", Self.photo.id])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    /// A link at the file's own name is not written through either.
    func testHomeFileWritesThroughNoLinkAtTheName() throws {
        let target = home.appendingPathComponent("target")
        try Data("kept".utf8).write(to: target)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("photos/a.jpg"), withDestinationURL: target)
        XCTAssertEqual(try HomeFile.create(Data("new".utf8), named: "a.jpg", in: ["photos"], under: home), .exists)
        XCTAssertEqual(try Data(contentsOf: target), Data("kept".utf8))
        HomeFile.remove(named: "b.jpg", in: ["nowhere"], under: home)
        XCTAssertEqual(try HomeFile.create(Data("new".utf8), named: "b.jpg", in: ["made", "deeper"], under: home), .created)
        HomeFile.remove(named: "b.jpg", in: ["made", "deeper"], under: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("made/deeper/b.jpg").path))
    }

    // MARK: Save

    func testASaveAddsThePictureAsItIsAndNothingElse() async {
        let library = Library()
        let png = Self.picture()
        let asked = LockedBox<[String]>([])
        let tool = tool(library, read: { path in
            asked.with { $0.append(path) }
            switch path {
            case "/home/topo/chart.png": return png
            case "notes.txt": return Data("not a picture".utf8)
            default: return nil
            }
        })
        let saved = await tool.run(["save", "/home/topo/chart.png"])
        XCTAssertEqual(saved, .ok("saved: NEW-1/L0/001\n"))
        XCTAssertEqual(library.added, [png])

        let text = await tool.run(["save", "notes.txt"])
        XCTAssertEqual(text.status, ToolReply.refused, text.text)
        let missing = await tool.run(["save", "/tmp/none.png"])
        XCTAssertEqual(missing.status, ToolReply.failed, missing.text)
        XCTAssertEqual(library.added, [png], "something that is not a readable picture reached the library")
        XCTAssertEqual(asked.with { $0 }, ["/home/topo/chart.png", "notes.txt", "/tmp/none.png"])
    }

    // MARK: PhotoKit

    func testAStillOverTheLongSideIsDrawnDown() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 100), format: format).image { _ in }
        let jpeg = try XCTUnwrap(PhotoKitLibrary.jpeg(wide, longSide: 200))
        let drawn = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(drawn.size.width * drawn.scale, 200)
        XCTAssertEqual(drawn.size.height * drawn.scale, 50)
        let small = try XCTUnwrap(UIImage(data: try XCTUnwrap(PhotoKitLibrary.jpeg(wide, longSide: 2048))))
        XCTAssertEqual(small.size.width * small.scale, 400)
    }

    /// PhotoKit itself takes every fetch the tool makes: a predicate it does not know is an
    /// exception, not an error, so each is sent to the simulator's own library, which is only read.
    /// Access is granted as for the contacts (`xcrun simctl privacy <udid> grant photos zone.hexagon.topo`).
    func testPhotoKitTakesEveryFetchTheToolMakes() async throws {
        // A grant reads as not determined until the library is asked, and asking answers at once
        // with no prompt; with no grant the prompt stays up, so the ask is bounded. simctl's own
        // grant is leave to add only on iOS 26: the PR check marks it full access (pr-validate.yaml).
        let status = await PhoneTool.within(.seconds(5)) { await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        XCTAssertEqual(status, .authorized,
                       "grant the simulator's photos access first: xcrun simctl privacy <udid> grant photos zone.hexagon.topo")
        guard status == .authorized else { return }
        let home = home!
        let tool = PhotosTool(library: PhotoKitLibrary(), authorizer: PhotosAuthorizer(), broker: PermissionBroker(), home: { home })
        let albums = await tool.run(["albums"])
        XCTAssertEqual(albums.status, ToolReply.ok, albums.text)
        for call in [["search", "--kind", "photo", "--favorites", "--from", "2001-01-01", "--to", "2099-01-01", "--limit", "3"],
                     ["search", "--kind", "video"], ["search", "--limit", "1"]] {
            let reply = await tool.run(call)
            XCTAssertEqual(reply.status, ToolReply.ok, "\(call): \(reply.text)")
        }
        let unknown = await tool.run(["search", "--album", "no-such-album"])
        XCTAssertEqual(unknown, .failed("topo: no album with the id no-such-album\n"))
        let gone = await tool.run(["export", "00000000-0000-0000-0000-000000000000/L0/001"])
        XCTAssertEqual(gone.status, ToolReply.failed, gone.text)

        // Whatever photo the simulator's library holds is exported; an empty library has none to try.
        let newest = await tool.run(["search", "--kind", "photo", "--limit", "1"])
        guard let id = newest.text.split(separator: "\n").first?.components(separatedBy: " | ").first, id.contains("/") else { return }
        let exported = await tool.run(["export", id])
        XCTAssertEqual(exported.status, ToolReply.ok, exported.text)
        let name = try PhotosTool.fileName(for: id)
        let image = try XCTUnwrap(UIImage(data: try Data(contentsOf: home.appendingPathComponent("photos/\(name)"))))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height) * image.scale, CGFloat(PhotosTool.longSide))
    }
}

/// A value behind a lock, for a closure the tool calls.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    @discardableResult func with<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

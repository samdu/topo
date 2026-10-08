import XCTest
import TopoUserland

/// A file read as the guest reads it (`Guest.contents(ofFile:from:limit:)`), in the booted
/// guest: its bytes exactly, by an absolute path or one from a directory, through the guest's
/// own mounts and links — and nil for what is no regular file, is too large, or is not there.
final class GuestFileReadTests: XCTestCase {
    private let fm = FileManager.default
    private var host: URL!
    private var point = ""
    private var tmp = ""
    /// Every byte value, twice: no text, and nothing a decode to a string would keep.
    private let bytes = Data((0..<512).map { UInt8($0 % 256) })

    override func setUp() async throws {
        _ = try SharedGuest.booted()
        let id = UUID().uuidString.prefix(8)
        host = fm.temporaryDirectory.appendingPathComponent("read-\(id)", isDirectory: true)
        try fm.createDirectory(at: host.appendingPathComponent("charts"), withIntermediateDirectories: true)
        try bytes.write(to: host.appendingPathComponent("charts/sizes.png"))
        try bytes.write(to: host.appendingPathComponent("-dash.png"))
        try bytes.write(to: host.appendingPathComponent("it's $(odd) \"name\".png"))
        point = "/opt/read-\(id)"
        try Guest.shared.mount(host, at: point)
        tmp = "/tmp/read-\(id)"
        let made = try await Guest.shared.run("/bin/sh", ["-c", """
            mkdir -p \(tmp)/dir && cp \(point)/charts/sizes.png \(tmp)/x.png && ln -s \(tmp)/x.png \(tmp)/link.png \
            && ln -s \(point)/charts \(tmp)/linked && ln -s \(tmp)/none \(tmp)/dangling.png && mkfifo \(tmp)/pipe.png
            """])
        XCTAssertEqual(made.status, 0, made.errors)
    }

    override func tearDown() async throws {
        _ = try? await Guest.shared.run("/bin/sh", ["-c", "rm -rf \(tmp)"])
        try? fm.removeItem(at: host)
    }

    private func read(_ path: String, from directory: String? = nil, limit: Int = 4096) async throws -> Data? {
        try await Guest.shared.contents(ofFile: path, from: directory ?? point, limit: limit)
    }

    func testAFileIsReadByteForByteByAnAbsolutePathOrOneFromTheDirectory() async throws {
        for path in ["\(tmp)/x.png", "\(point)/charts/sizes.png", "charts/sizes.png", "./charts/sizes.png",
                     "charts/../charts/sizes.png", "-dash.png", "it's $(odd) \"name\".png"] {
            let data = try await read(path)
            XCTAssertEqual(data, bytes, path)
        }
        let fromTmp = try await read("x.png", from: tmp)
        XCTAssertEqual(fromTmp, bytes)
    }

    /// The guest's links are the guest's to follow: to a file, and through a directory.
    func testTheGuestsLinksAreFollowed() async throws {
        let linked = try await read("\(tmp)/link.png")
        XCTAssertEqual(linked, bytes)
        let through = try await read("\(tmp)/linked/sizes.png")
        XCTAssertEqual(through, bytes)
    }

    /// A file larger than a pipe holds at once is read whole, and many reads at once all answer.
    func testALargeFileAndManyReadsAtOnce() async throws {
        let large = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try large.write(to: host.appendingPathComponent("large.bin"))
        let read = try await read("large.bin", limit: 400_000)
        XCTAssertEqual(read, large)
        let point = point, bytes = bytes
        let answers = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<16 {
                group.addTask { try? await Guest.shared.contents(ofFile: "charts/sizes.png", from: point, limit: 4096) }
            }
            var all: [Data?] = []
            for await answer in group { all.append(answer) }
            return all
        }
        XCTAssertEqual(answers, Array(repeating: bytes, count: 16))
    }

    /// A link to a pipe is a pipe, and is not read.
    func testALinkToAPipeIsNotRead() async throws {
        let made = try await Guest.shared.run("/bin/sh", ["-c", "ln -s \(tmp)/pipe.png \(tmp)/piped.png"])
        XCTAssertEqual(made.status, 0, made.errors)
        let data = try await read("\(tmp)/piped.png")
        XCTAssertNil(data)
    }

    /// A pipe would hold the read open, and a file past the limit is not read in part.
    func testWhatIsNoRegularFileOrIsTooLargeIsNil() async throws {
        for path in ["\(tmp)/none.png", "\(tmp)/dir", "\(tmp)/pipe.png", "\(tmp)/dangling.png", "", "charts", "/dev/zero",
                     "/proc/self/environ\0x"] {
            let data = try await read(path)
            XCTAssertNil(data, path.debugDescription)
        }
        let within = try await read("\(tmp)/x.png", limit: 512)
        XCTAssertEqual(within, bytes)
        let over = try await read("\(tmp)/x.png", limit: 511)
        XCTAssertNil(over, "a file over the limit was read")
        let nowhere = try await read("x.png", from: "\(tmp)/none")
        XCTAssertNil(nowhere, "a directory that is not there was read from")
    }
}

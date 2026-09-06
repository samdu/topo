import Foundation
import Network
import Testing
import TopoCore
@testable import TopoLink

@Suite struct SurfaceDocumentTests {
    let at = Date(timeIntervalSince1970: 1_757_100_000)

    func document(notice: String? = nil, complete: Bool = true) -> SurfaceDocument {
        SurfaceDocument(
            house: "Hexagon Zone",
            transcript: .init(complete: complete, notice: notice, turns: [
                .init(ref: "phone/1", role: "person", text: "Bins?", at: at),
            ]),
            board: .init(cards: [
                .init(id: "hub/3", owner: "hub", body: "Bins out tonight", state: "posted", postedAt: at, at: at),
            ]))
    }

    @Test func encodesTheShapeThePageReads() throws {
        let json = try document().json()
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("\"version\":1"))
        #expect(text.contains("\"house\":\"Hexagon Zone\""))
        #expect(text.contains("\"at\":\"2025-09-05T19:20:00Z\""))
        #expect(text.contains("\"notice\":null"))
        #expect(text.contains("\"role\":\"person\""))
        #expect(text.contains("\"state\":\"posted\""))
        // Round-trips, so what the page reads is what was built.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(SurfaceDocument.self, from: json) == document())
    }

    /// The ETag is a hash of the bytes, so it only has to be stable for the
    /// same document and different for a changed one.
    @Test func theSameDocumentHasTheSameETag() throws {
        let first = try document().json()
        let again = try document().json()
        #expect(SurfaceDocument.etag(for: first) == SurfaceDocument.etag(for: again))
        #expect(SurfaceDocument.etag(for: first) != SurfaceDocument.etag(for: try document(notice: "Careful").json()))
    }

    /// The log's own words, turned into the document: oldest first, and a
    /// read that could not be finished says so.
    @Test func readsFromATranscriptAndABoard() {
        let phone = DeviceID("phone")
        let first = Turn(ref: TurnRef(device: phone, sequence: 1), parents: [], role: .person, text: "Bins?", at: at)
        let second = Turn(ref: TurnRef(device: phone, sequence: 2), parents: [first.ref], role: .assistant,
                          text: "Tonight.", at: at.addingTimeInterval(2))
        let transcript = Transcript(turns: [second, first])
        let document = SurfaceDocument(house: "Hexagon Zone", transcript: transcript, notice: nil,
                                       board: TopoCore.Board(revisions: []))
        #expect(document.transcript.turns.map(\.ref) == ["phone/1", "phone/2"])
        #expect(document.transcript.turns.map(\.role) == ["person", "assistant"])
        #expect(document.transcript.complete)
        #expect(document.board.cards.isEmpty)

        let holed = Transcript(turns: [second])
        #expect(!SurfaceDocument(house: nil, transcript: holed, notice: "gone", board: TopoCore.Board(revisions: [])).transcript.complete)
    }
}

@Suite struct SurfacePageServerTests {
    let at = Date(timeIntervalSince1970: 1_757_100_000)
    let token = "0123456789abcdef0123456789abcdef"

    func document() -> SurfaceDocument {
        SurfaceDocument(house: "Hexagon Zone",
                        transcript: .init(complete: true, notice: nil, turns: [
                            .init(ref: "phone/1", role: "person", text: "Bins?", at: at),
                        ]),
                        board: .init(cards: []))
    }

    func server() throws -> SurfacePageServer {
        let known = token
        let document = document()
        return try SurfacePageServer(files: [
            "index.html": .init(data: Data("<!doctype html>".utf8), contentType: "text/html; charset=utf-8"),
            "womble.js": .init(data: Data("// womble".utf8), contentType: "text/javascript; charset=utf-8"),
        ]) { asked in asked == known ? document : nil }
    }

    func request(_ line: String, _ headers: [String: String] = [:]) -> HTTPRequest {
        var text = line + " HTTP/1.1\r\nHost: mac.local\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        return HTTPRequest(text)!
    }

    func answer(_ server: SurfacePageServer, _ request: HTTPRequest) async -> (status: String, body: String, headers: String) {
        let data = await server.answer(to: request)
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let head = parts[0]
        return (head.split(separator: "\r\n").first.map(String.init) ?? "",
                parts.count > 1 ? parts[1...].joined(separator: "\r\n\r\n") : "",
                head)
    }

    @Test func servesTheDocumentUnderTheScreensOwnToken() async throws {
        let server = try server()
        let answered = await answer(server, request("GET /s/\(token)/surface.json"))
        #expect(answered.status == "HTTP/1.1 200 OK")
        #expect(answered.body.contains("\"ref\":\"phone/1\""))
        #expect(answered.headers.contains("Content-Type: application/json; charset=utf-8"))
    }

    @Test func servesThePageBesideIt() async throws {
        let server = try server()
        #expect(await answer(server, request("GET /s/\(token)/")).body == "<!doctype html>")
        #expect(await answer(server, request("GET /s/\(token)/index.html")).body == "<!doctype html>")
        #expect(await answer(server, request("GET /s/\(token)/womble.js")).body == "// womble")
        // A file the page is not made of is not there.
        #expect(await answer(server, request("GET /s/\(token)/womble.css")).status.contains("404"))
    }

    /// An unknown token is a 404 with nothing said about whether it was ever
    /// real — and the page, reading a 404, clears what it was showing.
    @Test func anUnknownTokenIsNotFoundAndSaysNothingElse() async throws {
        let server = try server()
        let answered = await answer(server, request("GET /s/ffffffffffffffffffffffffffffffff/surface.json"))
        #expect(answered.status == "HTTP/1.1 404 Not Found")
        #expect(answered.body.isEmpty)
        #expect(!answered.headers.contains("ETag"))
    }

    @Test func aScreenThatHasMissedNothingIsAnswered304() async throws {
        let server = try server()
        let first = await answer(server, request("GET /s/\(token)/surface.json"))
        let etag = try #require(first.headers.split(separator: "\r\n").first { $0.hasPrefix("ETag: ") })
            .dropFirst("ETag: ".count)
        let again = await answer(server, request("GET /s/\(token)/surface.json", ["If-None-Match": String(etag)]))
        #expect(again.status == "HTTP/1.1 304 Not Modified")
        #expect(again.body.isEmpty)
        // A stale one gets the document.
        let stale = await answer(server, request("GET /s/\(token)/surface.json", ["If-None-Match": "\"nothing\""]))
        #expect(stale.status == "HTTP/1.1 200 OK")
    }

    @Test func nothingIsWrittenThroughThisServer() async throws {
        let server = try server()
        #expect(await answer(server, request("POST /s/\(token)/surface.json")).status.contains("405"))
        #expect(await answer(server, request("DELETE /s/\(token)/")).status.contains("405"))
    }

    @Test func aPathThatIsNotAScreensIsNotFound() async throws {
        let server = try server()
        for path in ["GET /", "GET /surface.json", "GET /s/\(token)", "GET /s//surface.json",
                     "GET /s/\(token)/../../etc/passwd", "GET /s/\(token)/.hidden"] {
            #expect(await answer(server, request(path)).status.contains("404"), "\(path)")
        }
    }

    @Test func routesReadThePathTheWayThePageAsks() {
        #expect(SurfacePageServer.route("/s/abc/")?.file == "index.html")
        #expect(SurfacePageServer.route("/s/abc/surface.json")?.token == "abc")
        #expect(SurfacePageServer.route("/s/abc/surface.json?from=elsewhere")?.file == "surface.json")
        #expect(SurfacePageServer.route("/s/abc/deeper/file")  == nil)
        #expect(SurfacePageServer.route("/other/abc/") == nil)
    }

    /// A token in a path is in the browser's history and in any proxy's log,
    /// so this is served to the house and to nobody else.
    @Test func onlyTheHouseIsAnswered() {
        for host: NWEndpoint.Host in ["127.0.0.1", "10.0.1.4", "192.168.1.20", "172.16.4.1", "169.254.3.3", "::1"] {
            #expect(SurfacePageServer.isLocal(.hostPort(host: host, port: 80)), "\(host)")
        }
        for host: NWEndpoint.Host in ["8.8.8.8", "172.32.1.1", "203.0.113.5", "2606:4700::1111"] {
            #expect(!SurfacePageServer.isLocal(.hostPort(host: host, port: 80)), "\(host)")
        }
    }

    /// End to end, the way a television asks.
    @Test func answersOverTheSocket() async throws {
        let server = try server()
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        try await connection.waitUntilReady()
        try await connection.send(Data("GET /s/\(token)/surface.json HTTP/1.1\r\nHost: mac.local\r\n\r\n".utf8))
        let status = try await connection.readLine(maximum: 128)
        #expect(status.trimmingCharacters(in: .whitespacesAndNewlines) == "HTTP/1.1 200 OK")
    }
}

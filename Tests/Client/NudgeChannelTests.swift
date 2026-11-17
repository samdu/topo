import Foundation
import TopoCore
import TopoCoreTesting
import TopoLink
import XCTest

/// The nudge's channel on iOS's own TLS: a phone with the hub's key from the zone opens it and is
/// streamed to, and one with another key is refused in the handshake. The package suite runs the
/// same on macOS; this is the phone's stack agreeing to the channel's version and suite.
final class NudgeChannelTests: XCTestCase {
    let hub = DeviceID("mac-\(UUID().uuidString.lowercased())")

    func testThePhonesStackOpensTheChannelWithTheKeyAndNotWithout() async throws {
        let nudges = NudgeCount()
        let key = NudgeKey.mint(hub: hub)
        let server = try LeaseProbeServer(advertising: nil, key: key, holds: { _, _ in false }) { _, epoch, _, stream in
            nudges.add()
            stream?(.text("Hello."))
            return epoch == 3
        }
        let port = try await server.start()
        let securePort = await server.securePort
        let channelPort = try XCTUnwrap(securePort)
        let lease = Lease(holder: hub, endpoint: "127.0.0.1:\(port)", epoch: 3, expiresAt: Date().addingTimeInterval(60))
        let db = InMemoryRecordDatabase()
        try await key.on(port: channelPort).save(to: db)
        let frames = NudgeFrames()
        let answer = await HubNudge.send(for: lease, mark: "ab12cd34", keys: NudgeKeys(), in: db, stream: { frames.add($0) })
        XCTAssertEqual(answer, .read)
        XCTAssertEqual(frames.all, [.text("Hello.")])
        XCTAssertEqual(nudges.count, 1)

        // Another key under the hub's name: refused in the handshake, nothing run.
        try await NudgeKey.mint(hub: hub).on(port: channelPort).save(to: db)
        let refused = await HubNudge.send(for: lease, mark: "ab12cd34", keys: NudgeKeys(), in: db)
        XCTAssertEqual(refused, .unreached("handshake"))
        XCTAssertEqual(nudges.count, 1)
        await server.stop()
    }
}

private final class NudgeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}

private final class NudgeFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [ReplyFrame] = []
    var all: [ReplyFrame] { lock.withLock { frames } }
    func add(_ frame: ReplyFrame) { lock.withLock { frames.append(frame) } }
}

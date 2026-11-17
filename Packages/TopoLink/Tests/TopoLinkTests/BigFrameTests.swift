import Foundation
import Network
import Testing
import TopoCore
@testable import TopoLink

/// A streamed reply's words handed in one frame longer than a line the phone reads
/// (`HubNudge.frameMaximum`): what `ReplyCast.follow` hands a follower that joins mid-reply.
@Suite struct BigFrameTests {
    final class Got: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [ReplyFrame] = []
        var frames: [ReplyFrame] { lock.withLock { all } }
        func add(_ f: ReplyFrame) { lock.withLock { all.append(f) } }
        var text: String { frames.reduce(into: "") { if case .text(let t) = $1 { $0 += t } } }
    }

    @Test func wordsPastALineGoAsSeveralFramesAndArriveWhole() async throws {
        let ref = TurnRef(device: DeviceID("phone-a"), sequence: 4)
        // Quotes, newlines, slashes and characters of several bytes, which the JSON line grows on.
        let big = String(repeating: "a \"word\"\n/ é 🦑 \u{1}", count: 7_000)
        let key = NudgeKey.mint(hub: DeviceID("mac-hub"))
        let server = try LeaseProbeServer(advertising: nil, key: key, holds: { _, _ in false }) { _, _, _, stream in
            guard let stream else { return false }
            stream(.turn([ref])); stream(.message); stream(.text(big)); stream(.text(" tail"))
            return true
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let got = Got()
        let lease = Lease(holder: DeviceID("mac-hub"), endpoint: "127.0.0.1:\(port)", epoch: 3, expiresAt: Date() + 10)
        // Mutant: the frame sent as one line (`frame.line`).
        let channel = key.on(port: try #require(await server.securePort))
        #expect(await HubNudge.send(for: lease, mark: "ab12cd34", key: channel, stream: { got.add($0) }) == .read)
        #expect(got.frames.prefix(2) == [.turn([ref]), .message])
        #expect(got.text == big + " tail")
        #expect(got.frames.count > 4)
    }

    @Test func aFrameIsSplitIntoLinesWithinTheBound() {
        let text = String(repeating: "\"\n\u{1}🦑", count: 5_000)
        let lines = ReplyFrame.text(text).lines(within: 4_096)
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { $0.count <= 4_096 && $0.last == UInt8(ascii: "\n") })
        let frames = lines.compactMap { ReplyFrame(line: String(decoding: $0.dropLast(), as: UTF8.self)) }
        #expect(frames.count == lines.count)
        #expect(frames.map { if case .text(let t) = $0 { t } else { "" } }.joined() == text)
        #expect(ReplyFrame.message.lines(within: 1) == [ReplyFrame.message.line])
    }
}

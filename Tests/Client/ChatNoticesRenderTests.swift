import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// The chat's notices (`ChatNotices`), read off what they say and off the pixels: the words are
/// the harness's, put together the one way, and the colours are the look's, so a failure in a
/// colour `look.json` chose reaches the bar rather than a red the view picked.
@MainActor
final class ChatNoticesRenderTests: XCTestCase {
    func testTheBusyLineSaysWhereTheTurnIsAndHowManyWaitBehindIt() {
        let busy = ChatNotices.Said(busy: true, status: "Asking Sonnet…", waiting: 3)
        XCTAssertEqual(busy.progress, "Asking Sonnet…")
        XCTAssertEqual(busy.queued, "· 2 waiting")
        let alone = ChatNotices.Said(busy: true, waiting: 1)
        XCTAssertEqual(alone.progress, "Working…", "a turn with no step yet still says it is going")
        XCTAssertNil(alone.queued, "the turn in flight is not one waiting")
        XCTAssertNil(ChatNotices.Said(waiting: 3).progress, "nothing in flight, no busy line")
        XCTAssertNil(ChatNotices.Said(waiting: 3).queued)
    }

    /// The fixtures the UI suite holds in the bar are the harness's own words.
    func testTheFixturesSayWhatTheHarnessSays() {
        XCTAssertEqual(DebugRun.notices(["TOPO_DEBUG_NOTICES": "error"])?.error,
                       "iCloud refused the read. Check you're signed in on this device.")
        XCTAssertEqual(DebugRun.notices(["TOPO_DEBUG_NOTICES": "info"])?.info,
                       "Another device is claiming primary. What you said is in the log; the reply will appear here.")
        let busy = DebugRun.notices(["TOPO_DEBUG_NOTICES": "busy"])
        XCTAssertEqual(busy?.progress, "Reaching iCloud…")
        XCTAssertEqual(busy?.queued, "· 2 waiting")
        XCTAssertNil(DebugRun.notices([:]))
    }

    func testTheFailureIsDrawnInTheLooksTrouble() throws {
        let failure = ChatNotices.Said(error: "iCloud refused the read. Check you're signed in on this device.")
        var look = Look()
        look.transcript.trouble = Self.probe
        XCTAssertGreaterThan(try count(Self.probe, in: ChatNotices(notices: failure), look: look), 20,
                             "the look's trouble colour never reached the failure's pixels")
        XCTAssertEqual(try count(Self.probe, in: ChatNotices(notices: failure), look: Look()), 0,
                       "the probe colour is in the picture without the look asking for it")
    }

    func testTheInfoLineAndTheQueueAreDrawnInTheLooksCaption() throws {
        var look = Look()
        look.transcript.caption = Self.probe
        let info = ChatNotices.Said(info: "Another device is claiming primary.")
        XCTAssertGreaterThan(try count(Self.probe, in: ChatNotices(notices: info), look: look), 20,
                             "the look's caption colour never reached the info line")
        let busy = ChatNotices.Said(busy: true, status: "Asking Sonnet…", waiting: 3)
        XCTAssertGreaterThan(try count(Self.probe, in: ChatNotices(notices: busy), look: look), 20,
                             "the look's caption colour never reached the waiting count")
        XCTAssertEqual(try count(Self.probe, in: ChatNotices(notices: info), look: Look()), 0)
    }

    // MARK: -

    /// A green nothing in the default look draws.
    private static let probe = Color(red: 0, green: 1, blue: 0)

    /// How many pixels are the probe colour to within a little antialiasing.
    private func count(_ colour: Color, in view: ChatNotices, look: Look) throws -> Int {
        let renderer = ImageRenderer(content: view
            .environment(\.look, look)
            .frame(width: 320)
            .background(Color.white))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage?.cgImage, "the notices rendered to nothing")
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var matches = 0
        for pixel in stride(from: 0, to: bytes.count, by: 4)
        where bytes[pixel] < 40 && bytes[pixel + 1] > 200 && bytes[pixel + 2] < 40 {
            matches += 1
        }
        return matches
    }
}

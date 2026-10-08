import SwiftUI
import UIKit
import TopoAuth
import TopoCore
import TopoTurn
import XCTest

@testable import Topo

/// The chat's notices (`ChatNotices`), read off what they say and off the pixels: the words are
/// the harness's, put together the one way, and the colours are the look's, so a failure in a
/// colour `look.json` chose reaches the bar rather than a red the view picked.
@MainActor
final class ChatNoticesRenderTests: XCTestCase {
    func testTheBusyLineSaysWhereTheTurnIsAndHowManyWaitBehindIt() {
        XCTAssertEqual(ChatNotices.Said(busy: true, status: "Asking Sonnet…", waiting: 3).notice,
                       .progress("Asking Sonnet…", queued: "· 2 waiting"))
        XCTAssertEqual(ChatNotices.Said(busy: true, waiting: 1).notice, .progress("Working…", queued: nil),
                       "a turn with no step yet still says it is going, and is not one waiting")
        XCTAssertNil(ChatNotices.Said(waiting: 3).notice, "nothing in flight, nothing to say")
    }

    /// The bar holds one notice: a failure over the turn in flight, and the turn in flight over a
    /// turn another primary took — which is what the bar shows when a second turn goes while the
    /// first went to the log for another device.
    func testTheBarSaysOneNoticeTheMostPressing() {
        let all = ChatNotices.Said(busy: true, status: "Asking Sonnet…", waiting: 2,
                                   error: "The log moved under us. Try again.", info: "Saved. hub will answer here.")
        XCTAssertEqual(all.notice, .trouble("The log moved under us. Try again."))
        var noError = all
        noError.error = nil
        XCTAssertEqual(noError.notice, .progress("Asking Sonnet…", queued: "· 1 waiting"))
        var infoOnly = noError
        infoOnly.busy = false
        XCTAssertEqual(infoOnly.notice, .info("Saved. hub will answer here."))
    }

    /// The fixtures the UI suite holds in the bar are the harness's own words.
    func testTheFixturesSayWhatTheHarnessSays() {
        let refused = ChatNotices.Notice.trouble("iCloud refused the read. Check you're signed in on this device.")
        XCTAssertEqual(DebugRun.notices(["TOPO_DEBUG_NOTICES": "error"])?.notice, refused)
        XCTAssertEqual(DebugRun.notices(["TOPO_DEBUG_NOTICES": "error-busy"])?.notice, refused)
        XCTAssertEqual(DebugRun.notices(["TOPO_DEBUG_NOTICES": "info"])?.notice,
                       .info("Saved. Another device will answer here."))
        XCTAssertEqual(DebugRun.notices(["TOPO_DEBUG_NOTICES": "busy"])?.notice,
                       .progress("Reaching iCloud…", queued: "· 2 waiting"))
        XCTAssertEqual(DebugRun.notices(["TOPO_DEBUG_NOTICES": "busy-long"])?.notice,
                       .progress("Checking this device is primary…", queued: "· 11 waiting"))
        let both = DebugRun.notices(["TOPO_DEBUG_NOTICES": "busy-info"])
        XCTAssertEqual(both?.info, Harness.limbInfo(.contended), "the fixture holds both")
        XCTAssertEqual(both?.notice, .progress("Reaching iCloud…", queued: "· 1 waiting"))
        XCTAssertNil(DebugRun.notices([:]))
    }

    /// Every notice the harness writes in its own words can be drawn whole in the two lines the
    /// bar holds, on the narrowest phone at the largest `noticeFont`: the bar leaves a notice
    /// the room measured (`room`) between the model and the mute and the badge, and one that does not fit
    /// there is drawn smaller, down to `look.transcript.noticeLeastScale`, before any of it is
    /// cut. So what is held is that each fits two lines at that least size. A failure carrying
    /// the system's own words (a guest's reason, a localized error) is not the harness's to
    /// shorten, and past two lines it is cut with an ellipsis.
    func testEveryNoticeTheHarnessWritesFitsTwoLinesOfTheBar() {
        let hub = Lease(holder: DeviceID("phone-1A2B3C4D"), endpoint: nil, epoch: 2, expiresAt: Date())
        let outcomes: [LeaseOutcome] = [.primary(hub), .held(by: hub), .unreachable(hub), .contended]
        let lines = outcomes.map(Harness.limbInfo) + [
            Harness.describe(RecordDatabaseError.rejected(underlying: CocoaError(.fileReadNoPermission))),
            Harness.describe(RecordDatabaseError.unavailable(underlying: CocoaError(.fileReadNoPermission))),
            Harness.describe(TurnLogError.sequenceContended(DeviceID("phone-1A2B3C4D"))),
            Harness.describe(TurnRunnerError.displaced),
            Harness.describe(TokenProviderError.signedOut),
            Harness.describe(GuestBridgeError.unresolved),
            "Saving what you said…", "Reaching iCloud…",
        ]
        for line in lines {
            XCTAssertLessThanOrEqual(Self.linesAtTheLeast(line, in: Self.room), CGFloat(ChatNotices.lines),
                                     "\"\(line)\" is more than two lines of the bar at its least size")
        }
    }

    /// The busy notice is the spinner and one text, where the turn is and then the count behind
    /// it, so what has to fit is the status with its count in the room the spinner leaves: every
    /// status the harness sets, with each model's name, and nothing, one or many waiting.
    func testEveryBusyNoticeFitsTwoLinesOfTheBarWithTheSpinnerAndTheCount() {
        let statuses = ["Reaching iCloud…", "Checking this device is primary…", "Saving what you said…",
                        "Saving the reply…", "Working…"] + ClaudeModel.allCases.map { "Asking \($0.displayName)…" }
        for status in statuses {
            for waiting in [1, 2, 12] {
                guard case .progress(let words, let queued) = ChatNotices.Said(busy: true, status: status, waiting: waiting).notice else {
                    return XCTFail("a turn in flight is not a progress notice")
                }
                let line = [words, queued].compactMap { $0 }.joined(separator: " ")
                XCTAssertLessThanOrEqual(Self.linesAtTheLeast(line, in: Self.room - Self.spinner),
                                         CGFloat(ChatNotices.lines),
                                         "\"\(line)\" is more than two lines of the bar beside the spinner")
            }
        }
    }

    /// At the default font, the statuses a turn passes through are drawn at their own size: none
    /// of them is long enough to be scaled.
    func testAStatusIsDrawnAtItsOwnSizeAtTheDefaultFont() {
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        for status in ["Reaching iCloud…", "Checking this device is primary…", "Saving what you said…", "Saving the reply…", "Working…"] {
            XCTAssertLessThanOrEqual(Self.lines(status, font: font, in: Self.room - Self.spinner), CGFloat(ChatNotices.lines), status)
        }
    }

    /// The room a notice has in the bar on a 390-point phone, between the model and the mute and
    /// the badge: the 196 points the running bar leaves it on a 402-point one, measured, since
    /// the bar lays its items out and says nothing of how, less the 12 the screen is narrower
    /// by. A turn in flight has that less the spinner and the room beside it. This suite is
    /// arithmetic over the harness's words; that the running bar draws a notice smaller before
    /// it cuts it is `TopoUITests/StatusNoticeTests`.
    private static let room: CGFloat = 184
    private static let spinner: CGFloat = 28

    /// How many lines `words` take in `width` at the largest `noticeFont` drawn at the look's
    /// least scale.
    private static func linesAtTheLeast(_ words: String, in width: CGFloat) -> CGFloat {
        let size = CGFloat(Look.Transcript.largestNotice) * Look().transcript.noticeLeastScale
        return lines(words, font: UIFont.systemFont(ofSize: size), in: width)
    }

    private static func lines(_ words: String, font: UIFont, in width: CGFloat) -> CGFloat {
        let needed = (words as NSString).boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin, attributes: [.font: font], context: nil)
        return (needed.height / font.lineHeight).rounded()
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
        let info = ChatNotices.Said(info: "Saved. Another device will answer here.")
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

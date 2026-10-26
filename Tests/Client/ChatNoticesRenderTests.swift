import SwiftUI
import UIKit
import Vision
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

    /// The fixtures the bar is held to, here and in the UI suite, are the harness's own words.
    func testTheFixturesSayWhatTheHarnessSays() {
        let refused = ChatNotices.Notice.trouble("iCloud refused the read. Check you're signed in on this device.")
        XCTAssertEqual(DebugRun.notices(["TOPO_DEBUG_NOTICES": "none"]), ChatNotices.Said())
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

    /// Each of `TOPO_DEBUG_NOTICES`'s fixtures laid out in a window in the room the bar leaves
    /// it, at the default look, saying its words and drawn whole: words that fit two lines at
    /// the notice's font are drawn as tall as they are unbounded, so neither cut nor scaled, and
    /// words that do not are drawn at the size they fit two lines at, so scaled before they are
    /// truncated. The failure is wrapped onto a second line rather than cut short.
    func testEachFixtureIsDrawnWholeInTheBarsRoom() throws {
        let look = Look()
        let size = UIFont.preferredFont(forTextStyle: .caption1).pointSize
        let line = try laid(Self.lines(1), look: look)
        for (fixture, words) in Self.fixtures {
            let said = try XCTUnwrap(DebugRun.notices(["TOPO_DEBUG_NOTICES": fixture]), fixture)
            let drawn = try whole(said, look: look, size: size, words: words, fixture)
            if fixture == "error" {
                XCTAssertGreaterThan(drawn, line * 1.5,
                                     "the failure is \(drawn) tall, one line of \(line), cut short rather than wrapped")
            }
        }
    }

    /// A look whose notice font is absurdly large, read through the document's reader as the
    /// phone reads it, still draws every fixture whole, in its words, at no more than two lines
    /// of the largest the bar holds (`Look.Transcript.largestNotice`, a look's own 15 points,
    /// measured): the size is drawn at 15 points, and the text-size setting reaches no further
    /// than `ChatNotices.largestType`.
    func testAnAbsurdNoticeFontIsDrawnAtNoMoreThanTwoLinesOfTheLargest() throws {
        let look = LookDocument.read(#"{"transcript": {"noticeFont": {"size": 400}}}"#).look
        let size = CGFloat(Look.Transcript.largestNotice)
        let tallest = try laid(Self.lines(2), look: Self.look(look, size: size))
        for (fixture, words) in Self.fixtures {
            let said = try XCTUnwrap(DebugRun.notices(["TOPO_DEBUG_NOTICES": fixture]), fixture)
            let drawn = try whole(said, look: look, size: size, words: words, fixture)
            XCTAssertLessThanOrEqual(drawn, tallest + 0.5,
                                     "\(fixture): drawn \(drawn) tall, more than two lines of the bar's largest, \(tallest)")
        }
    }

    /// `TOPO_DEBUG_NOTICES`'s fixtures that say something, and the words each has to show, written
    /// out rather than taken from the harness, so a change to what the bar draws is a failure here.
    private static let fixtures: [(String, String)] = [
        ("busy", "Reaching iCloud… · 2 waiting"),
        // The longest status the harness sets, beside the spinner and a two-digit count.
        ("busy-long", "Checking this device is primary… · 11 waiting"),
        ("error", "iCloud refused the read. Check you're signed in on this device."),
        ("info", "Saved. Another device will answer here."),
        // A turn left for another primary while the next is on its way: the bar holds one notice,
        // and the turn in flight is it.
        ("busy-info", "Reaching iCloud… · 1 waiting"),
        // A failure while a turn is on its way is the one notice.
        ("error-busy", "iCloud refused the read. Check you're signed in on this device."),
    ]

    /// The notice for `said` drawn in the bar's room under `look`, whose font is drawn at `size`
    /// points, and its height. What it says is `words`, read off its pixels, so a word changed,
    /// dropped or cut short in the drawing is a failure. Unbounded it is as tall as its words
    /// take; within the bar's two lines it is either that tall (they fit) or, where they take
    /// more, as tall as the whole of them laid out unbounded at the largest share of `size` they
    /// fit two lines at, found here independently of the view's own scaling. A notice the line
    /// limit cut, at any size, is shorter or taller than that by a line.
    private func whole(_ said: ChatNotices.Said, look: Look, size: CGFloat, words: String,
                       _ fixture: String) throws -> CGFloat {
        let drawn = try laid(ChatNotices(notices: said), look: look)
        let read = try Self.read(ChatNotices(notices: said), look: look)
        XCTAssertEqual(Self.normalized(read), Self.normalized(words),
                       "\(fixture): the bar's notice reads \"\(read)\", not \"\(words)\"")
        let unbounded = try laid(ChatNotices(notices: said, lineLimit: nil), look: look)
        if try fits(said, look: look, size: size, scale: 1) {
            XCTAssertEqual(drawn, unbounded, accuracy: 0.5,
                           "\(fixture): the words take \(unbounded) and were drawn \(drawn) tall, cut or scaled though they fit")
            return drawn
        }
        // The largest scale, to a hundredth, at which the whole of the words fit two lines.
        var low = look.transcript.noticeLeastScale, high: CGFloat = 1
        XCTAssertTrue(try fits(said, look: look, size: size, scale: low),
                      "\(fixture): the words do not fit two lines at the least the bar draws them")
        while high - low > 0.01 {
            let middle = (low + high) / 2
            if try fits(said, look: look, size: size, scale: middle) { low = middle } else { high = middle }
        }
        let whole = try laid(ChatNotices(notices: said, lineLimit: nil), look: Self.look(look, size: size * low))
        XCTAssertEqual(drawn, whole, accuracy: 1.5,
                       "\(fixture): the words take \(whole) whole at \(low) of their size and were drawn \(drawn) tall: cut short rather than drawn smaller")
        return drawn
    }

    /// Whether the whole of a notice's words, laid out unbounded at `scale` of `size`, is no
    /// taller than two lines at that size.
    private func fits(_ said: ChatNotices.Said, look: Look, size: CGFloat, scale: CGFloat) throws -> Bool {
        let scaled = Self.look(look, size: size * scale)
        let two = try laid(Self.lines(2), look: scaled)
        return try laid(ChatNotices(notices: said, lineLimit: nil), look: scaled) <= two + 0.5
    }

    /// `look` with its notice font a fixed `size`.
    private static func look(_ look: Look, size: CGFloat) -> Look {
        var look = look
        look.transcript.noticeFont = .system(size: size)
        return look
    }

    /// A notice of `count` lines, laid out unbounded, which is how tall that many lines of the
    /// look's font are: a line's height is SwiftUI's, which is not `UIFont.lineHeight`, so it is
    /// measured.
    private static func lines(_ count: Int) -> ChatNotices {
        ChatNotices(notices: ChatNotices.Said(info: Array(repeating: "Ag", count: count).joined(separator: "\n")),
                    lineLimit: nil)
    }

    /// `view` laid out in a window on the host app's scene, offered the bar's room, under `look`:
    /// how tall it is drawn, with the window's own text-size setting.
    private func laid(_ view: ChatNotices, look: Look) throws -> CGFloat {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        final class Size { var value: CGSize? }
        let size = Size()
        let wide = Self.room
        let laid = view
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size.value = $0 }
            .frame(width: wide)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.look, look)
            .transaction { $0.animation = nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: LookStage.size)
        window.rootViewController = UIHostingController(rootView: laid)
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for _ in 0..<4 { window.layoutIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let measured = try XCTUnwrap(size.value, "the notice was never laid out")
        XCTAssertLessThanOrEqual(measured.width, wide + 0.5, "the notice is wider than the room it was offered")
        return measured.height
    }

    /// The words `view` draws in the bar's room under `look`, read off its pixels by Vision's
    /// text recognition, top line first. The hosted view exposes no accessibility tree to a
    /// unit test, so what the notice says is read the way a person reads it.
    private static func read(_ view: ChatNotices, look: Look) throws -> String {
        let renderer = ImageRenderer(content: view
            .environment(\.look, look)
            .frame(width: room)
            .padding(12)
            .background(Color.white))
        renderer.scale = 4
        let image = try XCTUnwrap(renderer.uiImage?.cgImage, "the notice rendered to nothing")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    /// `words` as what is compared of a notice read off its pixels against the words it has to
    /// say, the whole of each and nothing else: lower-cased, its curly quotes straight, its
    /// ellipses three dots and its middle dots one mark, with every run of white space one
    /// space, and none at either end.
    private static func normalized(_ words: String) -> String {
        words.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .replacingOccurrences(of: "\u{2022}", with: "\u{00B7}")
            .replacingOccurrences(of: "\u{2219}", with: "\u{00B7}")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The room a notice has in the bar on a 390-point phone, between the model and the mute and
    /// the badge: the 196 points the running bar leaves it on a 402-point one, measured, since
    /// the bar lays its items out and says nothing of how, less the 12 the screen is narrower
    /// by. A turn in flight has that less the spinner and the room beside it. That the running
    /// bar holds a notice level with the badge, between it and the controls and above the
    /// transcript, is `TopoUITests/StatusNoticeTests`.
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

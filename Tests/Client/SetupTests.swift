import SwiftUI
import TopoUserland
import XCTest

@testable import Topo

/// The setup's lines (`Setup`): each part's own state read as a line, a line done only when
/// its part is, and the meter there while any is not.
@MainActor
final class SetupTests: XCTestCase {
    private let fetching = Setup.Fetch(fraction: 0.25, words: "downloading 57 MB of 228 MB")
    private let held = Setup.Fetch(fraction: nil, words: "waiting for a network the data settings allow")
    /// The meter as drawn: a part a quarter downloaded has a quarter of its bar in the tint and
    /// the rest in the track, a part being prepared a whole bar, and one not begun an empty one.
    func testABarIsFilledToItsPartsShare() throws {
        var look = Look()
        look.setup.tint = Color(red: 0, green: 1, blue: 0)
        look.setup.track = Color(red: 0, green: 0, blue: 1)
        look.setup.barWidth = 60
        look.setup.barHeight = 6
        func bar(_ state: Setup.State) throws -> (filled: Int, empty: Int) {
            let renderer = ImageRenderer(content: SetupMeter(lines: [Setup.Line(title: Setup.hearing, state: state)])
                .environment(\.look, look).padding(8).background(Color.white))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage?.cgImage, "the meter rendered to nothing")
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            func tint(_ x: Int, _ y: Int) -> Bool {
                let at = (y * image.width + x) * 4
                return bytes[at] < 60 && bytes[at + 1] > 180 && bytes[at + 2] < 60
            }
            func track(_ x: Int, _ y: Int) -> Bool {
                let at = (y * image.width + x) * 4
                return bytes[at] < 60 && bytes[at + 1] < 60 && bytes[at + 2] > 180
            }
            // The bar is the widest run of its two inks on any row; the mark beside it is the
            // tint's too, and is narrower and apart from it.
            var widest = (filled: 0, empty: 0)
            for y in 0..<image.height {
                var x = 0
                while x < image.width {
                    var filled = 0, empty = 0
                    while x < image.width, tint(x, y) { filled += 1; x += 1 }
                    while x < image.width, track(x, y) { empty += 1; x += 1 }
                    if filled + empty > widest.filled + widest.empty { widest = (filled, empty) }
                    if filled + empty == 0 { x += 1 }
                }
            }
            return widest
        }
        let whole = 60 * 3
        let quarter = try bar(.progress(0.25, "downloading 57 MB of 228 MB"))
        XCTAssertEqual(quarter.filled + quarter.empty, whole, accuracy: 6, "the bar is not the look's width")
        XCTAssertEqual(Double(quarter.filled) / Double(whole), 0.25, accuracy: 0.04, "a quarter downloaded drew \(quarter)")
        let prepared = try bar(.working("loading"))
        XCTAssertEqual(prepared.filled, whole, accuracy: 6, "a part being prepared drew \(prepared)")
        let waiting = try bar(.waiting("not started"))
        XCTAssertEqual(waiting.filled, 0, accuracy: 3, "a part not begun drew \(waiting)")
        XCTAssertEqual(waiting.empty, whole, accuracy: 6)
    }

    private let pin = ClaudeCodePin(version: "2.1.285", size: 1, sha256: String(repeating: "0", count: 64))

    /// The workspace is done only with the rootfs imported and Claude Code on the phone; either
    /// still fetching is a download, an import has no measure, and either failing says why.
    func testTheWorkspaceIsDoneOnlyWhenBothOfItsPartsAre() {
        let phases: [Userland.Phase] = [.fetching, .importing, .ready(.reused), .ready(.imported), .failed("no room")]
        let claudes: [Userland.ClaudePhase] = [.fetching, .fetched(pin), .failed("refused")]
        for phase in phases {
            for claude in claudes {
                let state = Setup.state(phase: phase, claude: claude, fetch: fetching)
                let ready: Bool = { if case .ready = phase, case .fetched = claude { return true } else { return false } }()
                XCTAssertEqual(state == .done, ready, "\(phase), \(claude): \(state)")
            }
        }
        XCTAssertEqual(Setup.state(phase: .fetching, claude: .fetching, fetch: fetching), .progress(0.25, fetching.words))
        XCTAssertEqual(Setup.state(phase: .ready(.reused), claude: .fetching, fetch: fetching), .progress(0.25, fetching.words))
        XCTAssertEqual(Setup.state(phase: .fetching, claude: .fetched(pin), fetch: held), .waiting(held.words))
        XCTAssertEqual(Setup.state(phase: .importing, claude: .fetching, fetch: fetching), .working("unpacking"))
        XCTAssertEqual(Setup.state(phase: .failed("no room"), claude: .fetched(pin), fetch: fetching), .failed("no room"))
        XCTAssertEqual(Setup.state(phase: .ready(.reused), claude: .failed("refused"), fetch: fetching), .failed("refused"))
    }

    /// The ear's and the voice's five steps, each its own line state, and done only when resident.
    func testAModelsLineIsDoneOnlyWhenItIsResident() {
        let stages: [Setup.Stage] = [.cold, .fetching, .loading, .ready, .failed("the model would not compile")]
        XCTAssertEqual(stages.map { Setup.state($0, fetch: fetching, loading: Ear.preparing) },
                       [.waiting("not started"), .progress(0.25, fetching.words), .working(Ear.preparing), .done,
                        .failed("the model would not compile")])
        XCTAssertEqual(Setup.state(.fetching, fetch: held, loading: Ear.preparing), .waiting(held.words))
        for state in [Ear.State.cold, .fetching, .loading, .ready, .failed] {
            XCTAssertEqual(Setup.stage(state, trouble: "why") == .ready, state == .ready, "\(state)")
        }
        for state in [Voice.State.cold, .fetching, .loading, .ready, .failed] {
            XCTAssertEqual(Setup.stage(state, trouble: "why") == .ready, state == .ready, "\(state)")
        }
        XCTAssertEqual(Setup.stage(Ear.State.failed, trouble: "why"), .failed("why"))
        XCTAssertEqual(Setup.stage(Voice.State.failed, trouble: nil), .failed("unknown"))
    }

    /// The meter is there while any line is not done, and gone when all three are: a part that
    /// failed keeps it up, saying why.
    func testTheMeterStandsWhileAnyLineIsNotDone() {
        func lines(_ phase: Userland.Phase, _ ear: Setup.Stage, _ voice: Setup.Stage) -> [Setup.Line] {
            Setup.lines(phase: phase, claude: .fetched(pin), workspace: fetching, ear: ear, earFetch: fetching,
                        earLoading: Ear.preparing, voice: voice, voiceFetch: fetching, voiceLoading: Voice.preparing)
        }
        let done = lines(.ready(.reused), .ready, .ready)
        XCTAssertEqual(done.map(\.title), [Setup.workspace, Setup.hearing, Setup.speaking])
        XCTAssertFalse(Setup.shows(done))
        XCTAssertFalse(Setup.shows([]), "a debug build with a stand-in has no meter")
        XCTAssertTrue(Setup.shows(lines(.fetching, .ready, .ready)))
        XCTAssertTrue(Setup.shows(lines(.ready(.reused), .loading, .ready)))
        XCTAssertTrue(Setup.shows(lines(.ready(.reused), .ready, .failed("no room"))))
    }

    /// A launch loads the ear and the voice every time, and that alone draws no meter: it comes
    /// for an install — a download, an unpacking, a failure — and then stands until every line is
    /// done, so the models' first preparing on this phone is under it.
    func testTheMeterComesForAnInstallAndStaysUntilEveryLineIsDone() {
        func lines(_ phase: Userland.Phase, _ ear: Setup.Stage, _ voice: Setup.Stage, fetch: Setup.Fetch? = nil) -> [Setup.Line] {
            Setup.lines(phase: phase, claude: .fetched(pin), workspace: fetch ?? fetching, ear: ear, earFetch: fetch ?? fetching,
                        earLoading: Ear.preparing, voice: voice, voiceFetch: fetch ?? fetching, voiceLoading: Voice.preparing)
        }
        // An ordinary launch: cold, then loading, then ready.
        for launch in [lines(.ready(.reused), .cold, .cold), lines(.ready(.reused), .loading, .cold), lines(.ready(.reused), .ready, .loading)] {
            XCTAssertFalse(Setup.installing(launch))
            XCTAssertFalse(Setup.standing(launch, stood: false), "a launch's own loading drew the meter")
        }
        // A launch with every file on the phone and the parts' own states a moment behind them:
        // the downloads say "downloaded" while the workspace, the ear and the voice still say
        // fetching, and nothing is being installed.
        let present = Setup.Fetch(fraction: nil, words: ModelDownloads.downloaded)
        let behind = lines(.fetching, .fetching, .fetching, fetch: present)
        XCTAssertEqual(behind.map(\.state), Array(repeating: .waiting(ModelDownloads.downloaded), count: 3))
        XCTAssertFalse(Setup.installing(behind))
        XCTAssertFalse(Setup.standing(behind, stood: false), "a launch with nothing to fetch drew the meter")
        let claudeBehind = Setup.lines(phase: .ready(.reused), claude: .fetching, workspace: present, ear: .loading, earFetch: present,
                                       earLoading: Ear.preparing, voice: .cold, voiceFetch: present, voiceLoading: Voice.preparing)
        XCTAssertFalse(Setup.standing(claudeBehind, stood: false))
        // An install: each of these brings it.
        for install in [lines(.fetching, .cold, .cold), lines(.importing, .cold, .cold), lines(.ready(.imported), .fetching, .cold),
                        lines(.ready(.reused), .ready, .fetching, fetch: held), lines(.ready(.reused), .failed("no room"), .ready),
                        lines(.failed("no room"), .ready, .ready)] {
            XCTAssertTrue(Setup.standing(install, stood: false), "\(install)")
        }
        // The voice held back for the ear's download is an install's wait; its compile waiting
        // for the ear's is every launch's, and alone draws nothing.
        let queued = Setup.Fetch(fraction: nil, words: ModelDownloads.queued)
        let voiceQueued = Setup.lines(phase: .ready(.reused), claude: .fetched(pin), workspace: present, ear: .ready, earFetch: present,
                                      earLoading: Ear.preparing, voice: .fetching, voiceFetch: queued, voiceLoading: Voice.preparing)
        XCTAssertEqual(voiceQueued.last?.state, .waiting(ModelDownloads.queued))
        XCTAssertTrue(Setup.standing(voiceQueued, stood: false))
        let afterEar = Setup.Fetch(fraction: nil, words: Voice.afterEar)
        let compileWaits = Setup.lines(phase: .ready(.reused), claude: .fetched(pin), workspace: present, ear: .loading, earFetch: present,
                                       earLoading: Ear.preparing, voice: .fetching, voiceFetch: afterEar, voiceLoading: Voice.preparing)
        XCTAssertEqual(compileWaits.last?.state, .waiting(Voice.afterEar))
        XCTAssertFalse(Setup.standing(compileWaits, stood: false), "a launch's voice waiting on its ear drew the meter")
        XCTAssertTrue(Setup.standing(compileWaits, stood: true), "an install's meter stays through the wait")
        // Once it stands it stays through the preparing, and goes when all three are done.
        XCTAssertTrue(Setup.standing(lines(.ready(.imported), .loading, .cold), stood: true))
        XCTAssertFalse(Setup.standing(lines(.ready(.imported), .ready, .ready), stood: true))
        XCTAssertFalse(Setup.standing([], stood: true))
    }

    /// A download that failed is a failure on the meter, in the downloads' own words for why,
    /// though the part is still waiting on it.
    func testAFailedDownloadIsAFailure() {
        let failed = Setup.Fetch(fraction: nil, words: "download failed: the server said 503")
        XCTAssertEqual(Setup.state(.fetching, fetch: failed, loading: Ear.preparing), .failed("the server said 503"))
        XCTAssertEqual(Setup.state(phase: .fetching, claude: .fetching, fetch: failed), .failed("the server said 503"))
        XCTAssertEqual(Setup.state(.fetching, fetch: held, loading: Ear.preparing), .waiting(held.words))
    }

    /// What a bar says to VoiceOver: where its part has got to, that it is ready, or why it failed.
    func testALineSaysWhereItIsOrWhyItFailed() {
        XCTAssertEqual(SetupMeter.words(.progress(0.25, "downloading 57 MB of 228 MB")), "downloading 57 MB of 228 MB")
        XCTAssertEqual(SetupMeter.words(.working("unpacking")), "unpacking")
        XCTAssertEqual(SetupMeter.words(.done), "ready")
        XCTAssertEqual(SetupMeter.words(.failed("no room")), "failed: no room")
        XCTAssertTrue(SetupMeter.failed(.failed("no room")))
        XCTAssertFalse(SetupMeter.failed(.waiting("not started")))
    }

    /// A part has a bar until it is done, with its own mark, filled by its bytes while it
    /// downloads, whole while it is prepared or has failed, and never past its ends.
    func testAPartHasABarUntilItIsDone() {
        let lines = [Setup.Line(title: Setup.workspace, state: .done),
                     Setup.Line(title: Setup.hearing, state: .progress(0.25, "downloading")),
                     Setup.Line(title: Setup.speaking, state: .working(Voice.preparing))]
        XCTAssertEqual(Setup.pending(lines).map(\.title), [Setup.hearing, Setup.speaking])
        XCTAssertEqual(lines.map(\.symbol), ["shippingbox", "ear", "mouth"])
        XCTAssertEqual(SetupMeter.fill(.progress(0.25, "")), 0.25)
        XCTAssertEqual(SetupMeter.fill(.progress(7, "")), 1)
        XCTAssertEqual(SetupMeter.fill(.progress(-1, "")), 0)
        XCTAssertEqual(SetupMeter.fill(.progress(.nan, "")), 0)
        XCTAssertEqual(SetupMeter.fill(.waiting("not started")), 0)
        XCTAssertEqual(SetupMeter.fill(.working("unpacking")), 1)
        XCTAssertEqual(SetupMeter.fill(.failed("no room")), 1)
        XCTAssertTrue(SetupMeter.unmeasured(.working("unpacking")))
        XCTAssertTrue(SetupMeter.unmeasured(.waiting("waiting for a network the data settings allow")))
        XCTAssertFalse(SetupMeter.unmeasured(.progress(0.5, "")))
        XCTAssertFalse(SetupMeter.unmeasured(.failed("no room")))
    }

    /// The bar's middle holds one thing: what the chat has to say before anything of the setup,
    /// then a part that failed in words, then the bars, and nothing when there is nothing.
    func testTheBarsMiddleTakesTurns() {
        let fetching = [Setup.Line(title: Setup.hearing, state: .progress(0.25, "downloading"))]
        let failed = [Setup.Line(title: Setup.hearing, state: .failed("no room"))]
        let done = [Setup.Line(title: Setup.hearing, state: .done)]
        let quiet = ChatNotices.Said()
        let busy = ChatNotices.Said(busy: true)
        let trouble = ChatNotices.Said(error: "iCloud is not answering")
        let info = ChatNotices.Said(info: "Answered from this phone")
        XCTAssertEqual(Setup.middle(said: quiet, standing: fetching), .meter(fetching))
        XCTAssertEqual(Setup.middle(said: busy, standing: fetching), .notices(busy))
        XCTAssertEqual(Setup.middle(said: trouble, standing: failed), .notices(trouble))
        XCTAssertEqual(Setup.middle(said: quiet, standing: failed), .notices(ChatNotices.Said(error: "Hearing you failed: no room")))
        XCTAssertEqual(Setup.middle(said: info, standing: failed), .notices(info), "a part that failed hid what the chat had to say")
        XCTAssertEqual(Setup.middle(said: info, standing: fetching), .notices(info))
        XCTAssertEqual(Setup.middle(said: busy, standing: failed), .notices(busy))
        XCTAssertEqual(Setup.middle(said: info, standing: []), .notices(info))
        XCTAssertEqual(Setup.middle(said: info, standing: done), .notices(info))
        XCTAssertNil(Setup.middle(said: quiet, standing: []))
        XCTAssertNil(Setup.middle(said: quiet, standing: done))
        XCTAssertNil(Setup.trouble(fetching))
    }

    /// The fixtures a UI suite draws the meter from, and the launch that has none of its own.
    func testTheDebugFixturesAreLinesTheMeterDraws() {
        XCTAssertEqual(DebugRun.setup(["TOPO_DEBUG_SETUP": "fetching"])?.map(\.state),
                       [.progress(0.25, "downloading 57 MB of 228 MB"), .working(Ear.preparing), .done])
        XCTAssertEqual(DebugRun.setup(["TOPO_DEBUG_SETUP": "failed"])?.first?.state, .failed("the download was refused"))
        XCTAssertNil(DebugRun.setup([:]))
        XCTAssertTrue(DebugRun.standsIn(["TOPO_DEBUG_EAR": "loading"]))
        XCTAssertTrue(DebugRun.standsIn(["TOPO_DEBUG_VOICE": "loading"]))
        XCTAssertFalse(DebugRun.standsIn(["TOPO_DEBUG_EAR": ""]))
    }
}

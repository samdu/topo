import TopoUserland
import XCTest

@testable import Topo

/// The setup card's lines (`Setup`): each part's own state read as a line, a line done only when
/// its part is, and the card there while any is not.
@MainActor
final class SetupTests: XCTestCase {
    private let fetching = Setup.Fetch(fraction: 0.25, words: "downloading 57 MB of 228 MB")
    private let held = Setup.Fetch(fraction: nil, words: "waiting for a network the data settings allow")
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

    /// The card is there while any line is not done, and gone when all three are: a part that
    /// failed keeps it up, saying why.
    func testTheCardStandsWhileAnyLineIsNotDone() {
        func lines(_ phase: Userland.Phase, _ ear: Setup.Stage, _ voice: Setup.Stage) -> [Setup.Line] {
            Setup.lines(phase: phase, claude: .fetched(pin), workspace: fetching, ear: ear, earFetch: fetching,
                        earLoading: Ear.preparing, voice: voice, voiceFetch: fetching, voiceLoading: Voice.preparing)
        }
        let done = lines(.ready(.reused), .ready, .ready)
        XCTAssertEqual(done.map(\.title), [Setup.workspace, Setup.hearing, Setup.speaking])
        XCTAssertFalse(Setup.shows(done))
        XCTAssertFalse(Setup.shows([]), "a debug build with a stand-in has no card")
        XCTAssertTrue(Setup.shows(lines(.fetching, .ready, .ready)))
        XCTAssertTrue(Setup.shows(lines(.ready(.reused), .loading, .ready)))
        XCTAssertTrue(Setup.shows(lines(.ready(.reused), .ready, .failed("no room"))))
    }

    /// What a line says beside its name: where it has got to, that it is ready, or why it failed.
    func testALineSaysWhereItIsOrWhyItFailed() {
        XCTAssertEqual(SetupCard.words(.progress(0.25, "downloading 57 MB of 228 MB")), "downloading 57 MB of 228 MB")
        XCTAssertEqual(SetupCard.words(.working("unpacking")), "unpacking")
        XCTAssertEqual(SetupCard.words(.done), "ready")
        XCTAssertEqual(SetupCard.words(.failed("no room")), "failed: no room")
        XCTAssertTrue(SetupCard.failed(.failed("no room")))
        XCTAssertFalse(SetupCard.failed(.waiting("not started")))
    }

    /// The fixtures a UI suite draws the card from, and the launch that has no card of its own.
    func testTheDebugFixturesAreLinesTheCardDraws() {
        XCTAssertEqual(DebugRun.setup(["TOPO_DEBUG_SETUP": "fetching"])?.map(\.state),
                       [.progress(0.25, "downloading 57 MB of 228 MB"), .working(Ear.preparing), .done])
        XCTAssertEqual(DebugRun.setup(["TOPO_DEBUG_SETUP": "failed"])?.first?.state, .failed("the download was refused"))
        XCTAssertNil(DebugRun.setup([:]))
        XCTAssertTrue(DebugRun.standsIn(["TOPO_DEBUG_EAR": "loading"]))
        XCTAssertTrue(DebugRun.standsIn(["TOPO_DEBUG_VOICE": "loading"]))
        XCTAssertFalse(DebugRun.standsIn(["TOPO_DEBUG_EAR": ""]))
    }
}

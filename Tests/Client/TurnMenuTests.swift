import TopoCore
import XCTest

@testable import Topo

/// What holding a turn offers. The items are a value rather than a block of buttons inside a
/// view, because a context menu is a gesture no test can press: which items each role gets, and
/// what each of them does, is asked here.
@MainActor
final class TurnMenuTests: XCTestCase {
    private func turn(_ role: TurnRole, _ text: String = "Paris.") -> Turn {
        Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 1), parents: [], role: role,
             text: text, at: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func titles(_ turn: Turn, replay: Replay = Replay(),
                        actions: TurnActions = TurnActions()) -> [String] {
        TurnMenu.items(for: turn, replay: replay, actions: actions, copy: { _ in }).map(\.title)
    }

    /// A screen with nothing behind it — the watch, the television, a viewer — offers copy and
    /// nothing else, whoever said the turn.
    func testAScreenWithNothingBehindItOffersOnlyCopy() {
        XCTAssertEqual(titles(turn(.assistant)), ["Copy"])
        XCTAssertEqual(titles(turn(.person)), ["Copy"])
    }

    /// A phone that can speak offers to say Topo's turn again. A person's own words are not
    /// Topo's to say, so theirs are not offered it.
    func testOnlyToposTurnIsOfferedSayingAgain() {
        let replay = Replay(canSpeak: true)
        XCTAssertEqual(titles(turn(.assistant), replay: replay), ["Say again", "Copy"])
        XCTAssertEqual(titles(turn(.person), replay: replay), ["Copy"])
    }

    /// While something is being said the offer on every row is the one that stops it: two replies
    /// over each other is noise.
    func testWhileSomethingIsBeingSaidTheOfferIsToStop() {
        let replay = Replay(speaking: true, canSpeak: true)
        XCTAssertEqual(titles(turn(.assistant), replay: replay), ["Stop", "Copy"])
    }

    /// A phone whose voice is not resident is offered nothing rather than an item it would hear
    /// nothing from; the diagnostics `voice` row is what says how far along it is.
    func testAPhoneWithNoVoiceIsOfferedNothingToSayItWith() {
        XCTAssertEqual(titles(turn(.assistant), replay: Replay(speaking: false, canSpeak: false)),
                       ["Copy"])
    }

    /// Edit is the person's own turn and only where there is a row to put the words back into.
    func testEditIsThePersonsOwnTurnAndOnlyWhereThereIsARowForIt() {
        let actions = TurnActions(edit: { _ in })
        XCTAssertEqual(titles(turn(.person), actions: actions), ["Edit", "Copy"])
        XCTAssertEqual(titles(turn(.assistant), actions: actions), ["Copy"])
        XCTAssertEqual(titles(turn(.person), actions: TurnActions()), ["Copy"])
    }

    /// Each item does what it reads, and Copy's destination is handed in rather than reached for,
    /// so the items can be read with no pasteboard behind them.
    func testEachItemDoesWhatItReads() {
        var copied: String?
        var edited: Turn?
        var said: String?
        let mine = turn(.person, "Morning.")
        let theirs = turn(.assistant, "Morning yourself.")

        let hers = TurnMenu.items(for: mine, actions: TurnActions(edit: { edited = $0 }),
                                  copy: { copied = $0 })
        hers.first { $0.title == "Edit" }?.act()
        hers.first { $0.title == "Copy" }?.act()
        XCTAssertEqual(edited?.text, "Morning.")
        XCTAssertEqual(copied, "Morning.")

        let his = TurnMenu.items(for: theirs, replay: Replay(canSpeak: true, say: { said = $0 }),
                                 copy: { copied = $0 })
        his.first { $0.title == "Say again" }?.act()
        his.first { $0.title == "Copy" }?.act()
        XCTAssertEqual(said, "Morning yourself.")
        XCTAssertEqual(copied, "Morning yourself.")
    }
}

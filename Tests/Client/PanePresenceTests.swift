import CoreFoundation
import XCTest

@testable import Topo

/// How much of a pane the pane is, read off the mapping rather than off a scroll. The chat hands
/// over two edges in one space and the look's rise; what comes back is what the composer draws
/// its surface at. It is a pure function precisely so the three cases are arithmetic here rather
/// than a scroll a simulator has to hold still at the right offset.
@MainActor
final class PanePresenceTests: XCTestCase {
    /// The pane's top edge, in the chat's space. The content's bottom edge is written relative
    /// to it in each test, which is the only relation the mapping has.
    private let paneTop: CGFloat = 700
    private let rise: CGFloat = 48

    /// The empty end of the transcript, and the resting end of a long one: the last turn stops
    /// above the pane because the bar insets the scroll view, so there is nothing under it to
    /// lens and no pane is drawn.
    func testContentThatEndsAboveThePaneIsNoPaneAtAll() {
        XCTAssertEqual(PanePresence.of(contentBottom: paneTop - 200, paneTop: paneTop,
                                       rise: rise, open: false), 0)
        XCTAssertEqual(PanePresence.of(contentBottom: paneTop, paneTop: paneTop,
                                       rise: rise, open: false), 0,
                       "content stopping exactly at the pane's edge is still nothing behind it")
    }

    /// Dragged far enough that the turns are behind the glass, the pane is a pane whole, and it
    /// stays one however much further the content runs.
    func testContentPastTheRiseIsThePaneWhole() {
        XCTAssertEqual(PanePresence.of(contentBottom: paneTop + rise, paneTop: paneTop,
                                       rise: rise, open: false), 1)
        XCTAssertEqual(PanePresence.of(contentBottom: paneTop + rise * 20, paneTop: paneTop,
                                       rise: rise, open: false), 1,
                       "the share is bounded, so a long transcript is not more than a pane")
    }

    /// The surface arrives as the content does: a share of the rise, not a step at the edge.
    func testContentHalfwayThroughTheRiseIsHalfAPane() {
        XCTAssertEqual(PanePresence.of(contentBottom: paneTop + rise / 2, paneTop: paneTop,
                                       rise: rise, open: false), 0.5, accuracy: 0.0001)
        XCTAssertEqual(PanePresence.of(contentBottom: paneTop + rise / 4, paneTop: paneTop,
                                       rise: rise, open: false), 0.25, accuracy: 0.0001)
    }

    /// The tinted pane is what says the microphone is open, so it does not depend on how much
    /// has been said: over an empty transcript it is the pane whole, like any other.
    func testAnOpenMicrophoneIsThePaneWholeWhateverIsBehindIt() {
        XCTAssertEqual(PanePresence.of(contentBottom: paneTop - 400, paneTop: paneTop,
                                       rise: rise, open: true), 1)
        XCTAssertEqual(PanePresence.of(contentBottom: paneTop + rise / 2, paneTop: paneTop,
                                       rise: rise, open: true), 1)
    }

    /// The rise is a parameter of the mapping, so the look's value reaches what is drawn: one
    /// geometry, two rises, two answers. That the chat hands it `look.composer.presenceRise` is
    /// by reading `ChatView.panePresence`, not by this test.
    func testTheRiseChangesTheValueAtOneGeometry() {
        let geometry = paneTop + 24
        XCTAssertEqual(PanePresence.of(contentBottom: geometry, paneTop: paneTop,
                                       rise: 48, open: false), 0.5, accuracy: 0.0001)
        XCTAssertEqual(PanePresence.of(contentBottom: geometry, paneTop: paneTop,
                                       rise: 96, open: false), 0.25, accuracy: 0.0001)
    }

    /// A rise of nothing has no share to take, so it is the step the share cannot express rather
    /// than a division by zero. A look can be given one, so it is answered rather than assumed
    /// away.
    func testARiseOfNothingIsAStepAtThePanesEdge() {
        XCTAssertEqual(PanePresence.of(contentBottom: paneTop, paneTop: paneTop,
                                       rise: 0, open: false), 0)
        XCTAssertEqual(PanePresence.of(contentBottom: paneTop + 1, paneTop: paneTop,
                                       rise: 0, open: false), 1)
    }
}

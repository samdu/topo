import XCTest

/// Where Topo sits, in the running chat: each placement over an empty chat, a full one and with the
/// keyboard up; a long press and a drag pins him, the pin outlives a relaunch and the keyboard never
/// rewrites it; a scroll that starts on him scrolls. Read off the badge's debug report
/// (`DebugRun.ChatReport`), whose frames are in the space he is drawn in; the microphone the system
/// finds says where that space is on the screen.
///
/// Every launch sets this device's override (`TOPO_DEBUG_TUNING`) or deliberately leaves it, and
/// the class leaves it empty behind it, so no pin outlives it into another suite.
final class TopoPlacementTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        addTeardownBlock {
            let app = ChatReading.launch(transcript: "empty", tuning: "")
            app.terminate()
        }
    }

    /// On the glass: over an empty chat and a full one the pane is drawn whole (presence 1) and
    /// his shelf is its top edge, in the trailing flank; with the keyboard up he rides the short
    /// pane, and back down with it.
    func testOnTheGlassHeSitsOnAPaneThatStays() throws {
        for transcript in ["empty", "full"] {
            let app = ChatReading.launch(transcript: transcript, tuning: #"{"mascot": {"placement": "glass"}}"#,
                                         softwareKeyboard: true)
            let mic = ChatReading.microphone(app)
            XCTAssertTrue(mic.waitForExistence(timeout: 60), "\(transcript): the chat screen")
            let (chat, topo) = try ChatReading.wait(app, "\(transcript): on the glass") { chat, topo in
                topo.roost == "glass" && topo.standing && chat.presence == 1
            }
            XCTAssertEqual(chat.placement, "glass")
            try assertOnTheGlass(topo, transcript)
            ChatReading.attach(app, "glass-\(transcript)", to: self)
            let resting = try XCTUnwrap(topo.paneRect).height
            ChatReading.raiseKeyboard(app)
            let (_, up) = try ChatReading.wait(app, "\(transcript): on the short glass") { chat, now in
                now.roost == "glass" && now.standing && (now.paneRect?.height ?? resting) < resting - 1
                    && chat.presence == 1
            }
            try assertOnTheGlass(up, "\(transcript), keyboard up")
            XCTAssertLessThan(try XCTUnwrap(up.box).minY, try XCTUnwrap(topo.box).minY, "he did not ride the pane up")
            ChatReading.attach(app, "glass-\(transcript)-keyboard", to: self)
            ChatReading.lowerKeyboard(app)
            let (_, down) = try ChatReading.wait(app, "\(transcript): back on the resting glass") { _, now in
                now.roost == "glass" && now.standing && ChatReading.near(now.frame, topo.frame)
            }
            try assertOnTheGlass(down, "\(transcript), keyboard down")
            app.terminate()
        }
    }

    /// Pinned: over an empty chat and a full one, his box's centre is the pin, a fraction of the
    /// transcript's frame carried to the pane's foot; with the keyboard up he is lifted clear of it,
    /// and with it gone he is back at the pin. The pin this device keeps is the same throughout.
    func testPinnedHeStandsAtThePinAndTheKeyboardOnlyLiftsHimWhileItIsUp() throws {
        let pin = [0.3, 0.8]
        for transcript in ["empty", "full"] {
            let app = ChatReading.launch(transcript: transcript,
                                         tuning: #"{"mascot": {"placement": "pinned", "pin": {"x": 0.3, "y": 0.8}}}"#,
                                         softwareKeyboard: true)
            XCTAssertTrue(ChatReading.microphone(app).waitForExistence(timeout: 60), "\(transcript): the chat screen")
            let (chat, topo) = try ChatReading.wait(app, "\(transcript): at the pin") { _, topo in
                topo.roost == "pinned" && topo.standing
            }
            XCTAssertEqual(chat.overridePin, pin)
            try assertAtThePin(topo, pin, transcript)
            XCTAssertEqual(chat.facing, "left", "\(transcript): his centre is left of the middle")
            ChatReading.attach(app, "pinned-\(transcript)", to: self)

            ChatReading.raiseKeyboard(app)
            let keyboard = app.keyboards.element.frame
            let mic = ChatReading.microphone(app)
            let (_, lifted) = try ChatReading.wait(app, "\(transcript): lifted clear of the keyboard") { _, now in
                guard now.standing, let box = now.box, let offset = ChatReading.offset(now, mic: mic) else { return false }
                return box.maxY + offset.dy <= keyboard.minY
            }
            XCTAssertEqual(try XCTUnwrap(lifted.box).midX, try XCTUnwrap(topo.box).midX, accuracy: 0.5)
            XCTAssertEqual(ChatReading.chat(app)?.overridePin, pin, "\(transcript): the keyboard rewrote the pin")
            ChatReading.attach(app, "pinned-\(transcript)-keyboard", to: self)

            ChatReading.lowerKeyboard(app)
            let (after, back) = try ChatReading.wait(app, "\(transcript): back at the pin", timeout: 30) { _, now in
                now.standing && ChatReading.near(now.frame, topo.frame)
            }
            XCTAssertEqual(after.overridePin, pin, "\(transcript): the keyboard rewrote the pin")
            XCTAssertEqual(back.pin, pin)
            app.terminate()
        }
    }

    /// Roaming is what main does: over an empty chat he stands in a gap, clear of the glass.
    func testRoamingIsTheDefault() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "")
        XCTAssertTrue(ChatReading.microphone(app).waitForExistence(timeout: 60))
        let (chat, topo) = try ChatReading.wait(app, "roaming in a gap") { _, topo in topo.roost == "gap" && topo.standing }
        XCTAssertEqual(chat.placement, "roam")
        XCTAssertNil(chat.overridePlacement)
        let box = try XCTUnwrap(topo.box), pane = try XCTUnwrap(topo.paneRect)
        XCTAssertLessThanOrEqual(box.maxY, pane.minY + 0.5, "roaming on the glass: \(topo)")
        app.terminate()
    }

    /// A long press on him and a drag pins him where the finger lets go: the report says a drag
    /// began and he is pinned, and the override this device keeps holds the pin. A relaunch finds
    /// him there; the keyboard raised and dismissed leaves the kept pin as it was and him back at it.
    func testALongPressAndADragPinHimAndThePinOutlivesARelaunch() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "", softwareKeyboard: true)
        let mic = ChatReading.microphone(app)
        XCTAssertTrue(mic.waitForExistence(timeout: 60))
        let (_, start) = try ChatReading.wait(app, "roaming in a gap") { _, topo in topo.roost == "gap" && topo.standing }
        let offset = try XCTUnwrap(ChatReading.offset(start, mic: mic))
        let box = try XCTUnwrap(start.box)
        let from = CGPoint(x: box.midX + offset.dx, y: box.midY + offset.dy)
        let to = CGPoint(x: 110, y: 300)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: from.x, dy: from.y))
            .press(forDuration: 1.2, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)))
        let (chat, dropped) = try ChatReading.wait(app, "pinned where the drag let go") { chat, topo in
            topo.roost == "pinned" && topo.standing && chat.overridePlacement == "pinned"
        }
        XCTAssertEqual(dropped.drags, 1, "the report does not say a drag began: \(dropped)")
        let placed = try XCTUnwrap(dropped.box)
        XCTAssertEqual(placed.midX + offset.dx, to.x, accuracy: 3, "not where the finger let go: \(dropped)")
        XCTAssertEqual(placed.midY + offset.dy, to.y, accuracy: 3, "not where the finger let go: \(dropped)")
        let pin = try XCTUnwrap(chat.overridePin)
        XCTAssertEqual(chat.placement, "pinned")
        XCTAssertEqual(chat.pin, pin, "the chat does not wear the pin it kept")
        ChatReading.attach(app, "dragged", to: self)
        app.terminate()

        // A relaunch that sets nothing: the kept pin is where he stands.
        let again = ChatReading.launch(transcript: "empty", tuning: nil, softwareKeyboard: true)
        XCTAssertTrue(ChatReading.microphone(again).waitForExistence(timeout: 60))
        let (relaunched, there) = try ChatReading.wait(again, "at the kept pin after a relaunch") { _, topo in
            topo.roost == "pinned" && topo.standing
        }
        XCTAssertEqual(relaunched.overridePin, pin)
        XCTAssertTrue(ChatReading.near(there.frame, dropped.frame), "not where he was left: \(there) against \(dropped)")

        ChatReading.raiseKeyboard(again)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(ChatReading.chat(again)?.overridePin, pin, "the keyboard rewrote the pin")
        ChatReading.lowerKeyboard(again)
        let (after, _) = try ChatReading.wait(again, "back at the pin", timeout: 30) { _, now in
            now.standing && ChatReading.near(now.frame, dropped.frame)
        }
        XCTAssertEqual(after.overridePin, pin, "the keyboard rewrote the pin")
        again.terminate()
    }

    /// A scroll that starts on him scrolls the transcript and begins no drag: the finger moves
    /// before the press would pick him up.
    func testAScrollStartingOnHimScrolls() throws {
        let app = ChatReading.launch(transcript: "full",
                                     tuning: #"{"mascot": {"placement": "pinned", "pin": {"x": 0.5, "y": 0.45}}}"#)
        let mic = ChatReading.microphone(app)
        XCTAssertTrue(mic.waitForExistence(timeout: 60))
        let (_, topo) = try ChatReading.wait(app, "at the pin") { _, topo in topo.roost == "pinned" && topo.standing }
        let offset = try XCTUnwrap(ChatReading.offset(topo, mic: mic))
        let box = try XCTUnwrap(topo.box)
        // Where the transcript's content ends, which a scroll moves.
        let before = try XCTUnwrap(ChatReading.chat(app)?.contentBottom, "the chat reports no scroll")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: box.midX + offset.dx, dy: box.midY + offset.dy))
        // Up the screen: the fixture is drawn from its top, so there is room to scroll that way.
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -250)))
        let deadline = Date().addingTimeInterval(5)
        var moved = ChatReading.chat(app)?.contentBottom ?? before
        while abs(moved - before) < 20, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            moved = ChatReading.chat(app)?.contentBottom ?? before
        }
        XCTAssertGreaterThan(abs(moved - before), 20, "the transcript did not scroll: \(before) → \(moved)")
        let after = try XCTUnwrap(ChatReading.chat(app)?.mascot)
        XCTAssertEqual(after.drags, 0, "a scroll began a drag: \(after)")
        XCTAssertEqual(after.placement, "pinned")
        XCTAssertEqual(ChatReading.chat(app)?.overridePin, [0.5, 0.45], "the scroll moved the pin")
        app.terminate()
    }

    // MARK: Helpers

    /// On the glass: the engine's shelf — 68 art pixels below his box's top at a scale of 1 — on
    /// the pane's top edge, his box in the trailing flank, clear of the well.
    private func assertOnTheGlass(_ topo: ChatReading.Topo, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let box = try XCTUnwrap(topo.box, file: file, line: line)
        let pane = try XCTUnwrap(topo.paneRect, file: file, line: line)
        let well = try XCTUnwrap(topo.wellRect, file: file, line: line)
        XCTAssertEqual(box.minY + 68, pane.minY, accuracy: 0.5, "\(label): not on the pane's top edge: \(topo)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(box.minX, well.maxX - 0.5, "\(label): over the well: \(topo)", file: file, line: line)
        XCTAssertLessThanOrEqual(box.maxX, pane.maxX + 0.5, "\(label): off the pane: \(topo)", file: file, line: line)
    }

    /// At the pin: his box's centre a fraction of the frame across and down, to a point.
    private func assertAtThePin(_ topo: ChatReading.Topo, _ pin: [Double], _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let box = try XCTUnwrap(topo.box, file: file, line: line)
        let frame = try XCTUnwrap(topo.pinFrame, file: file, line: line)
        XCTAssertEqual(box.midX, frame.minX + pin[0] * frame.width, accuracy: 1, "\(label): \(topo)", file: file, line: line)
        XCTAssertEqual(box.midY, frame.minY + pin[1] * frame.height, accuracy: 1, "\(label): \(topo)", file: file, line: line)
    }
}

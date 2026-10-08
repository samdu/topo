import TopoMascot
import TopoTurn
import XCTest

@testable import Topo

/// What the bar's controls stand on: what a model is called, whether replies are read, where the
/// model slider's stops are along it, and Topo under the stop chosen while the slider is open:
/// where he hangs, and that he glides there, along it and away again rather than being put.
@MainActor
final class ChatBarTests: XCTestCase {
    static let size = MascotSprite.size(scale: 1)
    static let reach = MascotSprite.reach(scale: 1)
    static let frame = 1.0 / 30

    /// The chat as `MascotPlacementTests` has it, and the open slider's three stops in the bar
    /// above the transcript, as `ChatBar.Stops` puts them for a slider 200 points wide in the
    /// middle of a 402-point screen.
    static let visible = MascotPlacementTests.visible
    static let slider = CGRect(x: 101, y: -40, width: 200, height: 36)
    static let stops = ChatBar.Stops(count: 3, width: 200, inset: 26)

    static func field(stop: Int? = nil, keyboard: Bool = false) -> MascotField {
        var field = MascotPlacementTests.field(keyboard: keyboard)
        field.stop = stop.map { stops.frame(of: $0, in: slider, least: 14) }
        return field
    }

    static func settings(_ placement: Look.Mascot.Placement = .roam) -> MascotRoam.Settings {
        MascotPlacementTests.settings(placement)
    }

    private func run(_ roam: inout MascotRoam, time: inout Double, for seconds: Double = 60) {
        let until = time + seconds
        repeat {
            time += Self.frame
            roam.advance(to: time)
        } while roam.needsTime && time < until
    }

    /// What the layer does with each geometry: the settings the slider makes of the look's, then
    /// the geometry.
    private func hand(_ roam: inout MascotRoam, _ field: MascotField, _ placement: Look.Mascot.Placement = .roam,
                      at time: Double) {
        roam.use(MascotPerch.sliding(Self.settings(placement), under: field, swim: 240))
        roam.observe(field, at: time)
    }

    // MARK: The line

    /// The stops stand evenly between the insets, a finger on the line is at the stop it is
    /// nearest, and a slider narrower than its two insets still has its stops inside it.
    func testTheStopsAreAlongTheLineAndAFingerIsAtTheNearest() {
        let stops = ChatBar.Stops(count: 3, width: 321, inset: 40)
        XCTAssertEqual([0, 1, 2].map(stops.x(of:)), [40, 160.5, 281])
        XCTAssertEqual([-50, 40, 99, 101, 160.5, 222, 4_000].map(stops.nearest(to:)), [0, 0, 0, 1, 1, 2, 2])
        XCTAssertNil(stops.nearest(to: .nan))
        XCTAssertNil(ChatBar.Stops(count: 0, width: 321, inset: 40).nearest(to: 10))
        let lone = ChatBar.Stops(count: 1, width: 321, inset: 40)
        XCTAssertEqual(lone.nearest(to: 10), 0)
        XCTAssertEqual(lone.x(of: 0), 160.5)
        // At each end of what a document asks, in the narrowest room the bar leaves a slider:
        // every stop inside it, in order, and a column to press under each.
        for (width, inset) in [(96.0, 80.0), (96, 8), (320, 80), (320, 8), (40, 80), (0, 26), (.infinity, .nan)] as [(CGFloat, CGFloat)] {
            let stops = ChatBar.Stops(count: 3, width: width, inset: inset)
            let xs = [0, 1, 2].map(stops.x(of:))
            XCTAssertEqual(xs, xs.sorted(), "\(width), \(inset)")
            XCTAssertTrue(xs.allSatisfy { $0 >= 0 && $0 <= stops.width && $0.isFinite }, "\(width), \(inset): \(xs)")
            XCTAssertLessThanOrEqual(stops.inset, stops.width / 4 + 1e-9)
            XCTAssertEqual(stops.nearest(to: xs[2] + 1), 2, "\(width), \(inset)")
        }
        // A stop's column on the screen is centred on where the slider draws its knob.
        let frame = Self.stops.frame(of: 2, in: Self.slider, least: 14)
        XCTAssertEqual(frame.midX, Self.slider.minX + Self.stops.x(of: 2), accuracy: 1e-9)
        XCTAssertEqual(frame.minY, Self.slider.minY)
        XCTAssertEqual(frame.height, Self.slider.height)
    }

    // MARK: Where he hangs

    /// Under each stop his body's axis is under the stop's middle and his reach's top is the
    /// transcript's; under a stop at the screen's edge his reach is held inside it; with no stop
    /// there is no such place and the look's settings stand.
    func testHeHangsAtTheTopOfTheTranscriptUnderTheChosenStop() throws {
        for index in 0..<3 {
            let field = Self.field(stop: index)
            let stop = try XCTUnwrap(field.stop)
            let box = try XCTUnwrap(MascotPerch.under(field, size: Self.size, reach: Self.reach))
            XCTAssertEqual(box.midX, stop.midX, accuracy: 1e-9)
            XCTAssertEqual(box.minY, Self.visible.minY + Self.reach.top, accuracy: 1e-9)
            XCTAssertEqual(box.size, Self.size)
            let sliding = MascotPerch.sliding(Self.settings(.glass), under: field, swim: 240)
            XCTAssertEqual(sliding.placement, .pinned)
            XCTAssertTrue(sliding.sliding)
            XCTAssertEqual(sliding.speed, 240)
        }
        for x in [-200, 0, 402, 900] as [CGFloat] {
            var field = Self.field()
            field.stop = CGRect(x: x, y: -40, width: 40, height: 36)
            let box = try XCTUnwrap(MascotPerch.under(field, size: Self.size, reach: Self.reach))
            XCTAssertGreaterThanOrEqual(box.minX - Self.reach.left, Self.visible.minX - 1e-9, "\(x)")
            XCTAssertLessThanOrEqual(box.maxX + Self.reach.right, Self.visible.maxX + 1e-9, "\(x)")
        }
        XCTAssertNil(MascotPerch.under(Self.field(), size: Self.size))
        for placement in Look.Mascot.Placement.allCases {
            XCTAssertEqual(MascotPerch.sliding(Self.settings(placement), under: Self.field(), swim: 240), Self.settings(placement))
            XCTAssertEqual(MascotPerch.sliding(Self.settings(placement), under: nil, swim: 240), Self.settings(placement))
        }
    }

    // MARK: Going there

    /// The slider opening is one glide from where he stands to under the chosen stop, at the
    /// swim; a new stop is one more, along the top of the transcript; and the slider shutting is
    /// a glide back to where his own placement has him, never a jump. With the keyboard up too.
    func testHeGlidesToTheSliderAlongItAndAway() throws {
        for placement in Look.Mascot.Placement.allCases {
            for keyboard in [false, true] {
                let what = "\(placement), keyboard \(keyboard)"
                var time = 0.0
                var roam = MascotRoam(Self.settings(placement), frame: Self.frame)
                hand(&roam, Self.field(keyboard: keyboard), placement, at: time)
                run(&roam, time: &time)
                let home = try XCTUnwrap(roam.position, "\(what): never placed")

                // Open, on the first stop.
                var moves = roam.moves
                hand(&roam, Self.field(stop: 0, keyboard: keyboard), placement, at: time)
                let there = try XCTUnwrap(roam.move, "\(what): put under the slider rather than glided")
                XCTAssertEqual(there.from, home, what)
                XCTAssertEqual(there.duration, Double(hypot(there.to.x - home.x, there.to.y - home.y) / 240), accuracy: 1e-9,
                               "\(what): not at the swim")
                XCTAssertEqual(roam.moves, moves + 1, what)
                run(&roam, time: &time)
                let first = try XCTUnwrap(MascotPerch.under(Self.field(stop: 0, keyboard: keyboard), size: Self.size, reach: Self.reach))
                XCTAssertEqual(try XCTUnwrap(roam.picture).midX, first.midX, accuracy: 1e-6, what)
                XCTAssertEqual(try XCTUnwrap(roam.picture).minY, first.minY, accuracy: 1e-6, what)
                XCTAssertFalse(roam.grabbable(at: CGPoint(x: first.midX, y: first.midY)), "\(what): picked up under the slider")

                // The last stop: one glide along the top.
                moves = roam.moves
                hand(&roam, Self.field(stop: 2, keyboard: keyboard), placement, at: time)
                let along = try XCTUnwrap(roam.move, "\(what): put at the new stop rather than glided")
                XCTAssertEqual(along.from.y, along.to.y, accuracy: 1e-6, "\(what): left the top on the way")
                XCTAssertEqual(roam.moves, moves + 1, what)
                run(&roam, time: &time)
                let last = try XCTUnwrap(MascotPerch.under(Self.field(stop: 2, keyboard: keyboard), size: Self.size, reach: Self.reach))
                XCTAssertEqual(try XCTUnwrap(roam.picture).midX, last.midX, accuracy: 1e-6, what)

                // Shut: back to his own placement.
                let hung = try XCTUnwrap(roam.position)
                hand(&roam, Self.field(keyboard: keyboard), placement, at: time)
                if placement == .glass, keyboard {
                    // On the short glass he is placed, glide or no (`MascotRoam.perch`).
                    XCTAssertNil(roam.move, what)
                } else {
                    let back = try XCTUnwrap(roam.move, "\(what): jumped away from the slider")
                    XCTAssertEqual(back.from, hung, what)
                    // He goes home as he came, at the swim: six times these settings' stroll.
                    XCTAssertEqual(back.pace, 240 / 40, accuracy: 1e-9, "\(what): strolled home")
                    XCTAssertEqual(roam.position, hung, "\(what): moved before the glide")
                }
                run(&roam, time: &time)
                XCTAssertNil(roam.move, what)
                XCTAssertFalse(roam.leaving, what)
                let ended = try XCTUnwrap(roam.picture, "\(what): nowhere once the slider shut")
                // A roaming Topo's home is the gap he was called from; a placed one's, his placement's.
                XCTAssertEqual(ended.origin.x, home.x, accuracy: 1, "\(what): not back where he was called from")
                XCTAssertEqual(ended.origin.y, home.y, accuracy: 1, "\(what): not back where he was called from")
                XCTAssertEqual(roam.roost.name, placement == .roam ? "gap" : placement == .glass ? "glass" : "pinned", what)
                XCTAssertTrue(roam.grabbable(at: CGPoint(x: ended.midX, y: ended.midY)), "\(what): not to be had at home")
            }
        }
    }

    /// With words down the whole column no place clears them, and where he hangs under the bar
    /// is as good as any: he still leaves it when the slider shuts, for where he was called from,
    /// whether he had a place before it opened or not.
    func testOverAFullTranscriptTheSliderShuttingStillSendsHimAway() throws {
        for placed in [true, false] {
            for keyboard in [false, true] {
                let what = "placed before \(placed), keyboard \(keyboard)"
                var full = MascotPlacementTests.field(full: true, keyboard: keyboard)
                var time = 0.0
                var roam = MascotRoam(Self.settings(), frame: Self.frame)
                if placed {
                    hand(&roam, full, at: time)
                    run(&roam, time: &time)
                }
                full.stop = Self.stops.frame(of: 0, in: Self.slider, least: 14)
                hand(&roam, full, at: time)
                run(&roam, time: &time)
                let hung = try XCTUnwrap(roam.picture, "\(what): nowhere under the slider")
                XCTAssertEqual(hung, MascotPerch.under(full, size: Self.size, reach: Self.reach), what)
                full.stop = nil
                hand(&roam, full, at: time)
                XCTAssertNotNil(roam.move, "\(what): left under the bar")
                run(&roam, time: &time)
                let ended = try XCTUnwrap(roam.picture, "\(what): nowhere once the slider shut")
                XCTAssertGreaterThan(hypot(ended.minX - hung.minX, ended.minY - hung.minY), Self.size.height / 2, "\(what): still under the bar")
                XCTAssertEqual(roam.roost.name, "gap", what)
            }
        }
    }

    /// A Topo whose reach does not fit under the bar is not called there: at the largest scale a
    /// document sets, on this phone and with the keyboard up, the look's own settings stand.
    func testATopoTooLargeForTheRoomIsNotCalled() {
        for scale in [3.5, 4] as [CGFloat] {
            for keyboard in [false, true] {
                let field = Self.field(stop: 1, keyboard: keyboard)
                let size = MascotSprite.size(scale: scale), reach = MascotSprite.reach(scale: scale)
                XCTAssertNil(MascotPerch.under(field, size: size, reach: reach), "\(scale), keyboard \(keyboard)")
                var settings = Self.settings(.roam)
                settings.size = size
                settings.reach = reach
                XCTAssertEqual(MascotPerch.sliding(settings, under: field, swim: 240), settings)
            }
        }
        // Where he fits, his reach is inside the room at every stop, the keyboard up too.
        for stop in 0..<3 {
            let field = Self.field(stop: stop, keyboard: true)
            let box = MascotPerch.under(field, size: Self.size, reach: Self.reach)
            XCTAssertTrue(box.map { field.room(Self.reach).insetBy(dx: -1e-6, dy: -1e-6).contains($0) } ?? false, "stop \(stop): \(String(describing: box))")
        }
    }

    /// On the glass, the keyboard rising as the slider shuts places him on the short pane at
    /// once: a glide there would cross the well and end under the keyboard's top edge on its way.
    func testOnTheGlassTheKeyboardRisingAsTheSliderShutsPlacesHim() throws {
        var time = 0.0
        var roam = MascotRoam(Self.settings(.glass), frame: Self.frame)
        hand(&roam, Self.field(), .glass, at: time)
        run(&roam, time: &time)
        for stop in 0..<3 {
            hand(&roam, Self.field(stop: stop), .glass, at: time)
            run(&roam, time: &time)
            XCTAssertEqual(roam.roost.name, "pinned", "stop \(stop)")
            // Shut, and gliding home; then the keyboard.
            hand(&roam, Self.field(), .glass, at: time)
            XCTAssertNotNil(roam.move, "stop \(stop)")
            time += Self.frame
            roam.advance(to: time)
            let risen = Self.field(keyboard: true)
            hand(&roam, risen, .glass, at: time)
            let home = try XCTUnwrap(MascotPlacementTests.glass(risen))
            XCTAssertNil(roam.move, "stop \(stop): still gliding with the keyboard up")
            XCTAssertEqual(roam.position, home.origin, "stop \(stop): not on the short glass")
            XCTAssertEqual(roam.roost.name, "glass", "stop \(stop)")
            hand(&roam, Self.field(), .glass, at: time)
            run(&roam, time: &time)
        }
    }

    /// Under the open slider he wears the head of the model chosen there, whatever the harness
    /// asks, and his own again once it is shut.
    func testUnderTheSliderHeWearsTheModelChosen() {
        let mascot = Mascot(model: ClaudeModel.haiku.rawValue)
        XCTAssertEqual(mascot.drawn, mascot.state)
        mascot.chosen = ClaudeModel.fable.rawValue
        XCTAssertEqual(mascot.drawn.model, ClaudeModel.fable.rawValue)
        XCTAssertEqual(mascot.state.model, ClaudeModel.haiku.rawValue)
        mascot.chosen = nil
        XCTAssertEqual(mascot.drawn, mascot.state)
    }

    /// The swim is a speed of the look's, read in the stroll's range.
    func testTheSwimIsReadInTheStrollsRange() {
        XCTAssertEqual(LookDocument.read(#"{"mascot": {"swimSpeed": 400}}"#).look.mascot.swimSpeed, 400)
        let slow = LookDocument.read(#"{"mascot": {"swimSpeed": 9}}"#)
        XCTAssertEqual(slow.look.mascot.swimSpeed, Look().mascot.swimSpeed)
        XCTAssertEqual(slow.notes.count, 1, "\(slow.notes)")
    }

    // MARK: Names

    /// What the bar's slider and the notice call a model is the look's name for it, and the family's
    /// where the look names none; a document sets one name without touching the others, and one
    /// it refuses costs that name alone.
    func testAModelIsCalledWhatTheLookCallsIt() {
        XCTAssertEqual(ClaudeModel.allCases.map { Look.Mind().name($0.rawValue) }, ClaudeModel.allCases.map(\.displayName))
        XCTAssertNil(Look.Mind().name(ClaudeModel.haiku.rawValue))
        let reading = LookDocument.read(#"{"mind": {"sonnet": "  Sonnet 5.5 ", "opus": "", "fable": 7}}"#)
        XCTAssertEqual(reading.look.mind.sonnet, "Sonnet 5.5")
        XCTAssertEqual(reading.look.mind.opus, "Opus")
        XCTAssertEqual(reading.look.mind.fable, "Fable")
        XCTAssertEqual(reading.notes.count, 2, "\(reading.notes)")
        for refused in [String(repeating: "m", count: Look.Mind.longest + 1), "two\nlines", "   "] {
            let data = try! JSONSerialization.data(withJSONObject: ["mind": ["opus": refused]])
            let read = LookDocument.read(String(data: data, encoding: .utf8))
            XCTAssertEqual(read.look.mind.opus, "Opus", refused.debugDescription)
            XCTAssertEqual(read.notes.count, 1, refused.debugDescription)
        }
    }

    /// Read aloud until somebody mutes: a phone never asked reads replies.
    func testRepliesAreReadAloudUntilMuted() throws {
        let name = "mute-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(Mute.readsAloud(defaults))
        defaults.set(false, forKey: Mute.key)
        XCTAssertFalse(Mute.readsAloud(defaults))
        defaults.set(true, forKey: Mute.key)
        XCTAssertTrue(Mute.readsAloud(defaults))
    }

    /// The chat's debug report carries the model the bar set apart from the model a request
    /// carries for it, which in a debug build is the pin whatever was set.
    func testTheReportCarriesTheModelSetApartFromTheModelAsked() throws {
        for model in ClaudeModel.allCases {
            let raw = DebugRun.chatReport(spoken: nil, turns: [], error: nil, speaker: Speaker.Report(), voice: .ready, model: model)
            let report = try JSONDecoder().decode(DebugRun.ChatReport.self, from: Data(raw.utf8))
            XCTAssertEqual(report.model, model.rawValue)
            XCTAssertEqual(report.effectiveModel, ClaudeModel.effective(model).rawValue)
            XCTAssertEqual(report.effectiveModel, ClaudeModel.haiku.rawValue, "a debug build asks \(model) unpinned")
        }
    }
}

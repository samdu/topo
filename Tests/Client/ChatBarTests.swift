import TopoMascot
import TopoTurn
import XCTest

@testable import Topo

/// What the bar's controls stand on: what a model is called, whether replies are read, where the
/// model slider's stops are along it, and Topo over the stop chosen while the slider is open:
/// where he sits, and that he glides there, along it and away again rather than being put.
@MainActor
final class ChatBarTests: XCTestCase {
    static let size = MascotSprite.size(scale: 1)
    static let reach = MascotSprite.reach(scale: 1)
    static let frame = 1.0 / 30

    /// The chat as `MascotPlacementTests` has it, and with the slider open its row across the
    /// top of the pane, which is taller by it, the transcript ending that much higher: three
    /// stops as `ChatBar.Stops` puts them along the pane's width.
    static let visible = MascotPlacementTests.visible
    static let row: CGFloat = 50
    static let inset: CGFloat = 40

    static func field(stop: Int? = nil, keyboard: Bool = false, full: Bool = false) -> MascotField {
        var field = MascotPlacementTests.field(full: full, keyboard: keyboard)
        guard let stop, var pane = field.pane else { return field }
        pane.origin.y -= row
        pane.size.height += row
        field.pane = pane
        field.visible.size.height -= row
        field.obstacles = field.obstacles.filter { $0.maxY < field.visible.maxY }
        let stops = ChatBar.Stops(count: 3, width: pane.width, inset: inset)
        let column = stops.column(least: 18)
        field.stop = CGRect(x: pane.minX + stops.x(of: stop) - column / 2, y: pane.minY + 4, width: column, height: 44)
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
        roam.use(MascotPerch.sliding(Self.settings(placement), over: field, swim: 240))
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
        // At each end of what a document asks, in panes from the widest to none at all:
        // every stop inside it, in order, and a column to press under each.
        for (width, inset) in [(256.0, 160.0), (256, 16), (700, 160), (700, 16), (40, 80), (0, 26), (.infinity, .nan)] as [(CGFloat, CGFloat)] {
            let stops = ChatBar.Stops(count: 3, width: width, inset: inset)
            let xs = [0, 1, 2].map(stops.x(of:))
            XCTAssertEqual(xs, xs.sorted(), "\(width), \(inset)")
            XCTAssertTrue(xs.allSatisfy { $0 >= 0 && $0 <= stops.width && $0.isFinite }, "\(width), \(inset): \(xs)")
            XCTAssertLessThanOrEqual(stops.inset, stops.width / 4 + 1e-9)
            XCTAssertEqual(stops.nearest(to: xs[2] + 1), 2, "\(width), \(inset)")
        }
    }

    // MARK: Where he sits

    /// Over each stop his body's axis is over the stop's middle and the engine's shelf is on the
    /// pane's top edge, on the resting pane and on the row over the keyboard; over a stop at the
    /// screen's edge his reach is held inside it; with no stop there is no such place and the
    /// look's settings stand.
    func testHeSitsOnThePanesTopEdgeOverTheChosenStop() throws {
        for keyboard in [false, true] {
            for index in 0..<3 {
                let field = Self.field(stop: index, keyboard: keyboard)
                let stop = try XCTUnwrap(field.stop), pane = try XCTUnwrap(field.pane)
                let box = try XCTUnwrap(MascotPerch.over(field, size: Self.size, reach: Self.reach))
                // On the row over the keyboard the pane is as wide as the screen nearly, and his
                // reach holds him in from an end stop.
                if !keyboard || index == 1 { XCTAssertEqual(box.midX, stop.midX, accuracy: 1e-9) }
                XCTAssertEqual(box.minY + CGFloat(Topo.shelfY) - MascotSprite.box.minY, pane.minY, accuracy: 1e-9)
                XCTAssertEqual(box.size, Self.size)
                XCTAssertGreaterThanOrEqual(box.minX - Self.reach.left, field.visible.minX - 1e-9)
                XCTAssertLessThanOrEqual(box.maxX + Self.reach.right, field.visible.maxX + 1e-9)
                let sliding = MascotPerch.sliding(Self.settings(.glass), over: field, swim: 240)
                XCTAssertEqual(sliding.placement, .pinned)
                XCTAssertTrue(sliding.sliding)
                XCTAssertEqual(sliding.speed, 240)
            }
        }
        for x in [-200, 0, 402, 900] as [CGFloat] {
            var field = Self.field(stop: 0)
            field.stop = CGRect(x: x, y: 540, width: 40, height: 44)
            let box = try XCTUnwrap(MascotPerch.over(field, size: Self.size, reach: Self.reach))
            XCTAssertGreaterThanOrEqual(box.minX - Self.reach.left, Self.visible.minX - 1e-9, "\(x)")
            XCTAssertLessThanOrEqual(box.maxX + Self.reach.right, Self.visible.maxX + 1e-9, "\(x)")
        }
        XCTAssertNil(MascotPerch.over(Self.field(), size: Self.size))
        for placement in Look.Mascot.Placement.allCases {
            XCTAssertEqual(MascotPerch.sliding(Self.settings(placement), over: Self.field(), swim: 240), Self.settings(placement))
            XCTAssertEqual(MascotPerch.sliding(Self.settings(placement), over: nil, swim: 240), Self.settings(placement))
        }
    }

    // MARK: Going there

    /// The slider opening is one glide from where he stands to over the chosen stop, at the
    /// swim; a new stop is one more, along the pane; and the slider shutting is
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
                let there = try XCTUnwrap(roam.move, "\(what): put over the slider rather than glided")
                XCTAssertEqual(there.from, home, what)
                XCTAssertEqual(there.duration, Double(hypot(there.to.x - home.x, there.to.y - home.y) / 240), accuracy: 1e-9,
                               "\(what): not at the swim")
                XCTAssertEqual(roam.moves, moves + 1, what)
                run(&roam, time: &time)
                let first = try XCTUnwrap(MascotPerch.over(Self.field(stop: 0, keyboard: keyboard), size: Self.size, reach: Self.reach))
                XCTAssertEqual(try XCTUnwrap(roam.picture).midX, first.midX, accuracy: 1e-6, what)
                XCTAssertEqual(try XCTUnwrap(roam.picture).minY, first.minY, accuracy: 1e-6, what)
                XCTAssertFalse(roam.grabbable(at: CGPoint(x: first.midX, y: first.midY)), "\(what): picked up over the slider")

                // The last stop: one glide along the pane.
                moves = roam.moves
                hand(&roam, Self.field(stop: 2, keyboard: keyboard), placement, at: time)
                let along = try XCTUnwrap(roam.move, "\(what): put at the new stop rather than glided")
                XCTAssertEqual(along.from.y, along.to.y, accuracy: 1e-6, "\(what): left the top on the way")
                XCTAssertEqual(roam.moves, moves + 1, what)
                run(&roam, time: &time)
                let last = try XCTUnwrap(MascotPerch.over(Self.field(stop: 2, keyboard: keyboard), size: Self.size, reach: Self.reach))
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

    /// With words down the whole column no place clears them, and where he sits over the slider
    /// is as good as any: he still leaves it when the slider shuts, for where he was called from,
    /// whether he had a place before it opened or not.
    func testOverAFullTranscriptTheSliderShuttingStillSendsHimAway() throws {
        for placed in [true, false] {
            for keyboard in [false, true] {
                let what = "placed before \(placed), keyboard \(keyboard)"
                let full = Self.field(keyboard: keyboard, full: true)
                var time = 0.0
                var roam = MascotRoam(Self.settings(), frame: Self.frame)
                if placed {
                    hand(&roam, full, at: time)
                    run(&roam, time: &time)
                }
                let open = Self.field(stop: 0, keyboard: keyboard, full: true)
                hand(&roam, open, at: time)
                run(&roam, time: &time)
                let hung = try XCTUnwrap(roam.picture, "\(what): nowhere over the slider")
                XCTAssertEqual(hung, MascotPerch.over(open, size: Self.size, reach: Self.reach), what)
                hand(&roam, full, at: time)
                XCTAssertNotNil(roam.move, "\(what): left over the slider")
                run(&roam, time: &time)
                let ended = try XCTUnwrap(roam.picture, "\(what): nowhere once the slider shut")
                XCTAssertGreaterThan(hypot(ended.minX - hung.minX, ended.minY - hung.minY), Self.size.height / 2, "\(what): still where the slider was")
                XCTAssertEqual(roam.roost.name, "gap", what)
            }
        }
    }

    /// A model's name is kept whole whatever knob and gap a look asks for: at every end of
    /// `look.composer.models`' ranges together, the knob, the gap and the name's line fit the
    /// slider's height, and a look they all fit as asked is drawn as asked.
    func testTheNamesLineIsKeptBeforeTheKnobAndTheGap() {
        for height in [32, 44, 96] as [CGFloat] {
            for knob in [2, 18, 44] as [CGFloat] {
                for spacing in [0, 5, 16] as [CGFloat] {
                    for name in [5, 13, 17, 24] as [CGFloat] {
                        let fit = ChatBar.Stops.fitted(knob: knob, spacing: spacing, in: height, over: name)
                        let what = "height \(height), knob \(knob), spacing \(spacing), name \(name): \(fit)"
                        XCTAssertLessThanOrEqual(fit.knob + fit.spacing + name, height, what)
                        XCTAssertGreaterThanOrEqual(min(fit.knob, fit.spacing), 0, what)
                        if knob + spacing + name <= height {
                            XCTAssertEqual([fit.knob, fit.spacing], [knob, spacing], what)
                        }
                    }
                }
            }
        }
        let asked = ChatBar.Stops.fitted(knob: 28, spacing: 16, in: 44, over: 17)
        XCTAssertEqual([asked.knob, asked.spacing], [27, 0], "the knob gives way after the gap")
        let odd = ChatBar.Stops.fitted(knob: .nan, spacing: -.infinity, in: 36, over: 60)
        XCTAssertEqual([odd.knob, odd.spacing], [0, 0])
    }

    /// The pane gives the slider's row back over several geometries after it shuts, each with
    /// the transcript a little taller: a roaming Topo gliding home ends where he was called from
    /// and not at the place nearest there in a geometry on the way.
    func testTheWayHomeFollowsThePaneGivingItsRowBack() throws {
        for keyboard in [false, true] {
            var time = 0.0
            var roam = MascotRoam(Self.settings(), frame: Self.frame)
            hand(&roam, Self.field(keyboard: keyboard), at: time)
            run(&roam, time: &time)
            let home = try XCTUnwrap(roam.picture, "keyboard \(keyboard): nowhere to begin with")
            hand(&roam, Self.field(stop: 0, keyboard: keyboard), at: time)
            run(&roam, time: &time)
            // Shut: the row goes in five steps, a frame apart.
            let shut = Self.field(keyboard: keyboard)
            for step in 1...5 {
                var field = shut
                let left = Self.row * CGFloat(5 - step) / 5
                field.pane?.origin.y -= left
                field.pane?.size.height += left
                field.visible.size.height -= left
                hand(&roam, field, at: time)
                time += Self.frame
                roam.advance(to: time)
            }
            XCTAssertNotNil(roam.move, "keyboard \(keyboard): put home rather than glided")
            run(&roam, time: &time)
            let ended = try XCTUnwrap(roam.picture, "keyboard \(keyboard): nowhere once the slider shut")
            XCTAssertEqual(ended.minX, home.minX, accuracy: 1, "keyboard \(keyboard)")
            XCTAssertEqual(ended.minY, home.minY, accuracy: 1, "keyboard \(keyboard): stopped short of where he was called from")
        }
    }

    /// The keyboard coming up or going down while the slider is open takes the pane and him with
    /// it: he is put over the stop where the pane now is, and not glided there under the
    /// keyboard and across the well.
    func testTheKeyboardMovingUnderTheOpenSliderPlacesHim() throws {
        for placement in Look.Mascot.Placement.allCases {
            for stop in 0..<3 {
                var time = 0.0
                var roam = MascotRoam(Self.settings(placement), frame: Self.frame)
                hand(&roam, Self.field(), placement, at: time)
                run(&roam, time: &time)
                hand(&roam, Self.field(stop: stop), placement, at: time)
                run(&roam, time: &time)
                for keyboard in [true, false] {
                    let what = "\(placement), stop \(stop), keyboard \(keyboard)"
                    let field = Self.field(stop: stop, keyboard: keyboard)
                    hand(&roam, field, placement, at: time)
                    XCTAssertNil(roam.move, "\(what): glided between the panes")
                    XCTAssertEqual(roam.picture, MascotPerch.over(field, size: Self.size, reach: Self.reach), what)
                    run(&roam, time: &time)
                }
            }
        }
    }

    /// The slider's row is on a pane with room to grow in only where that room still holds a well
    /// that can be pressed under it; a pane nothing measured has it.
    func testTheSlidersRowIsOnThePaneOnlyWhereTheWellStaysPressable() {
        let look = Look.Composer.Models()
        let row = Composer.Models.row(look)
        XCTAssertEqual(row, look.height + look.spacing + look.topInset)
        XCTAssertTrue(Composer.Models.fits(row: row, in: nil))
        XCTAssertTrue(Composer.Models.fits(row: row, in: row + Look.Composer.Well.pressable))
        XCTAssertFalse(Composer.Models.fits(row: row, in: row + Look.Composer.Well.pressable - 1))
        XCTAssertFalse(Composer.Models.fits(row: row, in: 0))
    }

    /// A Topo whose reach does not fit between the top of the transcript and the pane, or the
    /// transcript's width, is not called there, and the look's own settings stand.
    func testATopoWithNoRoomOverThePaneIsNotCalled() {
        var short = Self.field(stop: 1, keyboard: true)
        short.visible.size.height = 30
        short.pane?.origin.y = 34
        var narrow = Self.field(stop: 1)
        narrow.visible.size.width = Self.size.width + Self.reach.left + Self.reach.right - 1
        for (what, field) in [("short", short), ("narrow", narrow)] {
            XCTAssertNil(MascotPerch.over(field, size: Self.size, reach: Self.reach), what)
            XCTAssertEqual(MascotPerch.sliding(Self.settings(.roam), over: field, swim: 240), Self.settings(.roam), what)
        }
        // Not called, he is still to be had by a finger while the slider is open, as one called
        // is not: it is the pin that keeps him from a finger, not the open slider.
        let open = Self.field(stop: 1)
        for called in [false, true] {
            let settings = called ? MascotPerch.sliding(Self.settings(), over: open, swim: 240) : Self.settings()
            XCTAssertEqual(settings.sliding, called)
            var roam = MascotRoam(settings, frame: Self.frame)
            var time = 0.0
            roam.observe(open, at: time)
            run(&roam, time: &time)
            let box = roam.picture
            XCTAssertNotNil(box, "called \(called): nowhere")
            XCTAssertEqual(box.map { roam.grabbable(at: CGPoint(x: $0.midX, y: $0.midY)) }, !called, "called \(called)")
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

    /// Over the open slider he wears the head of the model chosen there, whatever the harness
    /// asks, and his own again once it is shut.
    func testOverTheSliderHeWearsTheModelChosen() {
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

    /// What the model slider and the notice call a model is the look's name for it, and the family's
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

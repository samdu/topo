import SwiftUI
import TopoCore
import UIKit
import XCTest

@testable import Topo

/// What a reply's markdown draws, read off the pixels, under the phone's, the watch's and the
/// television's looks: a fence in its own enclosure and inside the column, inline styles drawn
/// and not only carried, headings bigger than words, and the person's turn drawn as typed.
///
/// Rows are drawn through `LookStage`, a real window, because a phone's fence scrolls sideways
/// and `ImageRenderer` lays out nothing inside a `ScrollView`; and through `TurnRow`, so the text
/// is drawn by the same renderer that reads its lines for Topo (`MascotLines`).
@MainActor
final class MarkdownRenderTests: XCTestCase {
    private let stage = CGSize(width: 393, height: 520)
    /// The code block's outline, in a colour nothing else on the stage is.
    private let outline = UIColor(red: 1, green: 0, blue: 0.5, alpha: 1)
    /// A quote's bars, and a quote's words, each in a colour of its own: a bar counted by its
    /// pixels alone would be indistinguishable from one bar of twice the width, and from the
    /// enclosure of a fence inside the quote.
    private let barInk = UIColor(red: 0, green: 0.6, blue: 1, alpha: 1)
    private let quoteInk = UIColor(red: 0, green: 0.5, blue: 0, alpha: 1)
    /// The transcript's caption ink, which a code block's number is drawn in.
    private let captionInk = UIColor(red: 1, green: 0.5, blue: 0, alpha: 1)

    private func turn(_ role: TurnRole, _ text: String) -> Turn {
        Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 1), parents: [], role: role,
             text: text, at: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A screen's look with the code block outlined in `outline`, so where it is drawn is a
    /// colour the test can find.
    private func look(_ screen: Look.Screen) -> Look {
        var look = Look(screen)
        look.markdown.codeBlock.accent = Color(outline)
        look.markdown.codeBlock.strokeWidth = 2
        look.markdown.quoteBar = Color(barInk)
        look.markdown.quoteText = Color(quoteInk)
        return look
    }

    private func draw(_ turn: Turn, _ look: Look, cue: CodeBlockCue? = nil) throws -> Pixels {
        let row = VStack(spacing: 0) {
            TurnRow(turn: turn, cue: cue)
                .padding(.horizontal, look.transcript.horizontalPadding)
            Spacer(minLength: 0)
        }
        .frame(width: stage.width, height: stage.height, alignment: .top)
        .background(Color.white)
        return try Pixels(LookStage.image(row, look: look, size: stage))
    }

    private let long = "```\n" + String(repeating: "let aVeryLongName = anotherVeryLongName; ", count: 6) + "\n```"

    /// A fence draws its enclosure and words with none do not, on every screen.
    func testAFenceIsDrawnInItsOwnEnclosure() throws {
        for screen in Look.Screen.allCases {
            let fenced = try draw(turn(.assistant, "Here:\n\n```\nlet x = 1\n```"), look(screen))
            XCTAssertGreaterThan(fenced.count(outline), 20, "\(screen): no enclosure round the fence")
            let bare = try draw(turn(.assistant, "Here:\n\nlet x = 1"), look(screen))
            XCTAssertEqual(bare.count(outline), 0, "\(screen): an enclosure with no fence")
        }
    }

    /// Each code block carries its number in the reply — what the voice says in its place, "See
    /// code block N" — drawn over the block at its trailing edge in the caption's ink, on every
    /// screen. Which digit is drawn is read off the pixels: each caption is matched against the
    /// digits drawn alone in the same type and ink, and has to be nearer its own number than the
    /// other block's, so the same number on both blocks fails.
    func testACodeBlockIsCaptionedWithItsNumber() throws {
        for screen in Look.Screen.allCases {
            var look = look(screen)
            look.transcript.caption = Color(captionInk)
            let pixels = try draw(turn(.assistant, "```\nlet x = 1\n```\n\n```\nlet y = 2\n```"), look)
            let blocks = try XCTUnwrap(pixels.rowRuns(outline), "\(screen): no enclosure")
            XCTAssertEqual(blocks.count, 2, "\(screen): two fences drew \(blocks)")
            guard blocks.count == 2 else { continue }
            let columns = try XCTUnwrap(pixels.columns(outline))
            let trailingHalf = (columns.lowerBound + columns.count / 2)...columns.upperBound
            let digits = try ["1", "2"].map { digit in
                let alone = Text(digit).font(look.transcript.labelFont).foregroundStyle(Color(captionInk))
                    .padding(8).background(Color.white)
                let drawn = try Pixels(LookStage.image(alone, look: look, size: CGSize(width: 80, height: 80)))
                return try XCTUnwrap(drawn.mask(rows: 0..<drawn.height, columns: 0...(drawn.width - 1)),
                                     "\(screen): \(digit) drew nothing alone")
            }
            var above = 0
            for (index, block) in blocks.enumerated() {
                let caption = pixels.mask(rows: above..<block.lowerBound, columns: trailingHalf)
                above = block.upperBound + 1
                let drawn = try XCTUnwrap(caption, "\(screen): no number over block \(index + 1)")
                let own = Self.overlap(drawn, digits[index])
                let other = Self.overlap(drawn, digits[1 - index])
                XCTAssertGreaterThan(own, other,
                                     "\(screen): block \(index + 1)'s caption reads more like \(2 - index) (\(own) vs \(other))")
            }
        }
    }

    /// The pulse's ink, a colour nothing else on the stage is.
    private let pulseInk = UIColor(red: 0.5, green: 0, blue: 1, alpha: 1)

    /// The outline a reached code block breathes with, in its two states: at rest it draws
    /// nothing — before the pulse, between its two breaths and at its end — and at the peak of
    /// each breath it rings the block's enclosure in the look's accent, inside the enclosure's own
    /// edge, at the look's width. A block the voice has not reached draws nothing either.
    func testAReachedBlocksOutlineBreathesInTheAccentAndRestsAtNothing() throws {
        var look = look(.phone)
        look.markdown.codePulse.accent = Color(pulseInk)
        // Opaque, so the peak is the ink itself rather than a blend of it a match cannot name.
        look.markdown.codePulse.opacity = 1
        look.markdown.codePulse.width = 3
        let pulse = look.markdown.codePulse
        let reply = turn(.assistant, "Here:\n\n```\nlet x = 1\n```")
        func at(_ time: Double?, number: Int = 1) throws -> Pixels {
            try draw(reply, look, cue: time.map { CodeBlockCue(reply: reply.ref, number: number, serial: 1, still: $0) })
        }
        let unreached = try at(nil)
        let enclosure = try XCTUnwrap(unreached.columns(outline))
        let enclosureRows = try XCTUnwrap(unreached.rows(outline))
        XCTAssertEqual(unreached.count(pulseInk), 0, "an unreached block pulses")
        for rest in [0, pulse.cycle, pulse.duration, pulse.duration + 1] {
            XCTAssertEqual(try at(rest).count(pulseInk), 0, "at \(rest)s the outline is drawn")
        }
        XCTAssertEqual(try at(pulse.cycle / 2, number: 2).count(pulseInk), 0, "another block's cue pulsed this one")
        for peak in [pulse.cycle / 2, pulse.cycle * 1.5] {
            let drawn = try at(peak)
            let columns = try XCTUnwrap(drawn.columns(pulseInk), "nothing drawn at the peak, \(peak)s")
            let rows = try XCTUnwrap(drawn.rows(pulseInk))
            // Round the enclosure and inside it, to a pixel of antialiasing.
            XCTAssertEqual(columns.lowerBound, enclosure.lowerBound, accuracy: 2)
            XCTAssertEqual(columns.upperBound, enclosure.upperBound, accuracy: 2)
            XCTAssertEqual(rows.lowerBound, enclosureRows.lowerBound, accuracy: 2)
            XCTAssertEqual(rows.upperBound, enclosureRows.upperBound, accuracy: 2)
            // A ring, the width of the look's: its left edge is that many points of the ink.
            let middle = (rows.lowerBound + rows.upperBound) / 2
            let thick = drawn.run(pulseInk, row: middle, from: columns.lowerBound)
            XCTAssertEqual(CGFloat(thick) / drawn.scale, pulse.width, accuracy: 1, "the ring is \(thick) pixels at the peak")
            XCTAssertLessThan(drawn.count(pulseInk), (columns.count * rows.count) / 3, "the block is filled, not outlined")
        }
    }

    /// What the pulse ink blends to over anything at a part of its opacity: far bluer than it is
    /// green or red, which neither the page, the enclosure, its outline nor the code's ink is.
    private func pulsing(_ pixels: Pixels, rows: ClosedRange<Int>) -> Int {
        var n = 0
        for y in rows where y >= 0 && y < pixels.height {
            for x in 0..<pixels.width {
                let i = (y * pixels.width + x) * 4
                let r = Int(pixels.bytes[i]), g = Int(pixels.bytes[i + 1]), b = Int(pixels.bytes[i + 2])
                if b - g > 60 && b - r > 30 { n += 1 }
            }
        }
        return n
    }

    /// The cue a live transcript is handed, which the test moves on as the speaker does.
    @Observable fileprivate final class LiveCue {
        var cue: CodeBlockCue?
        /// Whether the row is made at all: a lazy stack's row, before it is scrolled to.
        var made = true
    }

    fileprivate struct LiveRow: View {
        let turn: Turn
        let live: LiveCue
        let size: CGSize
        let padding: CGFloat
        var body: some View {
            VStack(spacing: 0) {
                if live.made {
                    TurnRow(turn: turn, cue: live.cue)
                        .padding(.horizontal, padding)
                }
                Spacer(minLength: 0)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color.white)
        }
    }

    fileprivate struct LiveTranscript: View {
        let turns: [Turn]
        let live: LiveCue
        var body: some View { TranscriptView(turns: turns, cue: live.cue) }
    }

    /// Played live, as the phone plays it: the voice reaching block 1 pulses block 1, and then
    /// moving on to block 2 pulses block 2 alone — block 1's outline stays at rest, though its
    /// cue has just gone.
    func testOnlyTheBlockTheCueNamesPulses() throws {
        var look = look(.phone)
        look.markdown.codePulse.accent = Color(pulseInk)
        look.markdown.codePulse.opacity = 1
        look.markdown.codePulse.width = 3
        look.markdown.codePulse.cycle = 1.5
        let pulse = look.markdown.codePulse
        let reply = turn(.assistant, "One:\n\n```\nlet x = 1\n```\n\nTwo:\n\n```\nlet y = 2\n```")
        // Where each block's ring is, from a still of each at its peak.
        func ring(_ number: Int) throws -> ClosedRange<Int> {
            let still = try draw(reply, look, cue: CodeBlockCue(reply: reply.ref, number: number, serial: 1,
                                                               still: pulse.cycle / 2))
            let rows = try XCTUnwrap(still.rows(pulseInk), "block \(number) drew no ring at its peak")
            return (rows.lowerBound - 2)...(rows.upperBound + 2)
        }
        let first = try ring(1), second = try ring(2)
        XCTAssertLessThan(first.upperBound, second.lowerBound, "the fixture's blocks overlap")
        XCTAssertEqual(pulsing(try draw(reply, look), rows: 0...Int(self.stage.height * 4)), 0,
                       "the page pulses with no cue")

        let live = LiveCue()
        let stage = try LiveStage(LiveRow(turn: reply, live: live, size: self.stage,
                                          padding: look.transcript.horizontalPadding), look: look, size: self.stage)
        defer { stage.close() }
        func snapshot() throws -> Pixels { try Pixels(stage.image()) }
        // The row drawn, both blocks' outlines on the stage, before either is cued.
        var ready = false
        try stage.poll(for: 5) { [self] in
            ready = (try snapshot().rowRuns(outline)?.count ?? 0) >= 2
            return ready
        }
        XCTAssertTrue(ready, "the row was not drawn")
        // Looked at every tenth of a second from the cue until the pulse it starts is over by its
        // own clock and the cued block has been seen pulsing, for up to five seconds past its end,
        // so a picture taken late on a loaded runner is waited for rather than landing on a rest:
        // the most each block pulsed in any look.
        func watch(_ number: Int, serial: Int) throws -> (first: Int, second: Int) {
            live.cue = CodeBlockCue(reply: reply.ref, number: number, serial: serial)
            let over = Date().addingTimeInterval(pulse.duration)
            var most = (first: 0, second: 0)
            try stage.poll(for: pulse.duration + 5) { [self] in
                let drawn = try snapshot()
                most.first = max(most.first, pulsing(drawn, rows: first))
                most.second = max(most.second, pulsing(drawn, rows: second))
                return Date() >= over && (number == 1 ? most.first : most.second) > 20
            }
            return most
        }

        let reached = try watch(1, serial: 1)
        XCTAssertGreaterThan(reached.first, 20, "block 1 did not pulse on its cue")
        XCTAssertEqual(reached.second, 0, "block 2 pulsed on block 1's cue")
        // Its pulse over, block 1 comes to rest and stays there for a breath's length.
        var rest = false
        try stage.poll(for: 5) { [self] in
            rest = pulsing(try snapshot(), rows: first) == 0
            return rest
        }
        XCTAssertTrue(rest, "block 1 still pulsing after its pulse")
        var after = 0
        try stage.poll(for: pulse.cycle) { [self] in
            after = max(after, pulsing(try snapshot(), rows: first))
            return false
        }
        XCTAssertEqual(after, 0, "block 1 pulsed again after its pulse")

        let drawn = try watch(2, serial: 2)
        XCTAssertGreaterThan(drawn.second, 20, "block 2 did not pulse on its cue")
        XCTAssertEqual(drawn.first, 0, "block 1 pulsed on block 2's cue")
    }

    /// A view in a real window with its clock running, as the phone draws it: what a still
    /// cannot show, an animation under way and a lazy row made as it is scrolled to.
    @MainActor private final class LiveStage {
        let window: UIWindow
        let size: CGSize

        init(_ view: some View, look: Look, size: CGSize) throws {
            self.size = size
            let host = UIHostingController(rootView: view.environment(\.look, look))
            // Laid out from the window's top edge as the stills are, not under the status bar.
            host.safeAreaRegions = []
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: scene.screen.bounds.size)
            // The view on a stage at the window's top left, as `LookStage` draws the stills.
            let holder = UIViewController()
            holder.addChild(host)
            holder.view.addSubview(host.view)
            host.view.frame = CGRect(origin: .zero, size: size)
            host.didMove(toParent: holder)
            window.rootViewController = holder
            window.isHidden = false
            window.makeKeyAndVisible()
        }

        func wait(_ seconds: TimeInterval) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { RunLoop.current.run(mode: .default, before: min(until, Date().addingTimeInterval(0.01))) }
        }

        /// Turns the clock a tenth of a second at a time until `done`, asked after each, says so,
        /// for up to `seconds`; what was not seen by then is the caller's to fail on.
        func poll(for seconds: TimeInterval = 10, _ done: () throws -> Bool) rethrows {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                wait(0.1)
                if try done() { return }
            }
        }

        func image() -> UIImage {
            UIGraphicsImageRenderer(size: size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// A block the voice reaches in a reply the lazy transcript has not made yet — far above,
    /// scrolled away from — is scrolled to and pulses: its row is made with the cue already set.
    func testABlockInARowNotYetMadeIsScrolledToAndPulses() throws {
        let reached = try reach("Here:\n\n```\nlet x = 1\n```", first: true)
        XCTAssertGreaterThan(reached.shown, 20, "the block was not scrolled into view")
        XCTAssertGreaterThan(reached.pulsed, 20, "the block was scrolled to and did not pulse")
    }

    /// The same, the block at the foot of a reply far taller than the screen: bringing the row in
    /// shows its top, and the block is scrolled to once the row has made it.
    func testABlockAtTheFootOfATallRowNotYetMadeIsScrolledToAndPulses() throws {
        let paragraphs = (1...30).map { "Paragraph \($0) of a long reply, which takes a line or two of the column." }
        let reached = try reach(paragraphs.joined(separator: "\n\n") + "\n\n```\nlet x = 1\n```", first: true)
        XCTAssertGreaterThan(reached.shown, 20, "the block at the foot of the tall row was not scrolled into view")
        XCTAssertGreaterThan(reached.pulsed, 20, "the block was scrolled to and did not pulse")
    }

    /// A block already whole on the screen, cued, pulses where it is: the transcript does not
    /// move by a point.
    func testABlockAlreadyOnTheScreenIsNotScrolled() throws {
        let reached = try reach("Here:\n\n```\nlet x = 1\n```", first: false)
        XCTAssertGreaterThan(reached.pulsed, 20, "the block did not pulse")
        XCTAssertEqual(reached.moved, 0, "the transcript scrolled for a block already on the screen")
    }

    /// A live transcript of 40 turns with `text` as its first reply (off the screen, its row not
    /// made, the transcript opening at its end) or its last (on the screen), and that reply's
    /// first block cued: the most of the block's enclosure and of the pulse any picture showed
    /// while the pulse ran, and how far the transcript scrolled.
    private func reach(_ text: String, first: Bool) throws -> (shown: Int, pulsed: Int, moved: CGFloat) {
        var look = look(.phone)
        look.markdown.codePulse.accent = Color(pulseInk)
        look.markdown.codePulse.opacity = 1
        look.markdown.codePulse.width = 3
        // A breath slower than a look can make one (0.3–5 s), because the pulse is judged from
        // pictures of a transcript this long, which take seconds each on a loaded runner: at 5 s a
        // picture every 5 s lands on the rest between the breaths and on the end, and sees none of
        // it. At 12 s the first breath is past the 0.62 of its peak a ring over the outline is
        // told apart at from about 3.5 s to 8.5 s after it starts, so any picture taken then finds it.
        look.markdown.codePulse.cycle = 12
        let device = DeviceID("phone")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let filler = (2...40).map { n in
            Turn(ref: TurnRef(device: device, sequence: n), parents: [], role: n.isMultiple(of: 2) ? .person : .assistant,
                 text: "Turn \(n), long enough to take a line or two of the transcript's column.", at: at)
        }
        let reply = Turn(ref: TurnRef(device: device, sequence: first ? 1 : 41), parents: [], role: .assistant,
                         text: text, at: at)
        let turns = first ? [reply] + filler : filler + [reply]
        let live = LiveCue()
        let stage = try LiveStage(LiveTranscript(turns: turns, live: live)
            .frame(width: self.stage.width, height: self.stage.height).background(Color.white),
                                  look: look, size: self.stage)
        defer { stage.close() }
        try stage.poll(for: 5) { Self.scrollView(in: stage.window) != nil }
        let scroll = try XCTUnwrap(Self.scrollView(in: stage.window), "no scroll view")
        // Where the transcript stands before the cue is the test's to arrange, not the opening's to
        // be waited for: a lazy stack estimates the rows it has not made from the ones it has, and
        // while it does the content grows and shrinks under the opening, which on a loaded runner
        // lands seconds late, a third of a row short or at the very end. So the transcript is read
        // through once, to its top and back, as a person scrolling back would, until its content is
        // the fixture's own height laid out whole — every row measured, none estimated, and nothing
        // left to move it — and then put where it opens: its end, less the transcript's padding.
        // That leaves room under it, so a scroll the cue should not make — the block's top to the
        // screen's — moves the transcript rather than being held at the end.
        let whole = UIHostingController(rootView: VStack(alignment: .leading, spacing: look.transcript.spacing) {
            ForEach(turns) { TurnRow(turn: $0) }
        }
        .padding(.horizontal, look.transcript.horizontalPadding)
        .padding(.vertical, look.transcript.spacing)
        .frame(width: self.stage.width)
        .environment(\.look, look))
        let height = whole.sizeThatFits(in: CGSize(width: self.stage.width, height: .greatestFiniteMagnitude)).height
        func end() -> CGFloat { scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height }
        func page(to y: CGFloat) {
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            stage.window.layoutIfNeeded()
        }
        func measured() -> Bool { abs(scroll.contentSize.height - height) < 1 }
        let room = look.transcript.spacing
        func placed() -> Bool { abs(scroll.contentOffset.y - (end() - room)) < 0.5 }
        // Each is waited for up to five seconds, the block where the fixture puts it, off the
        // screen or on it, read once the rest holds; a move after is the cue's.
        var before = 0
        try stage.poll(for: 5) {
            for _ in 0..<200 where scroll.contentOffset.y > 0 { page(to: max(0, scroll.contentOffset.y - scroll.bounds.height)) }
            for _ in 0..<200 where scroll.contentOffset.y < end() - 1 { page(to: min(end(), scroll.contentOffset.y + scroll.bounds.height)) }
            page(to: end() - room)
            guard measured(), placed() else { return false }
            before = try Pixels(stage.image(), blank: true).count(outline)
            return first ? before == 0 : before > 20
        }
        XCTAssertTrue(measured(), "the transcript's rows were not all measured: \(scroll.contentSize.height) of \(height)")
        XCTAssertTrue(placed(), "the transcript is not where it opens: \(scroll.contentOffset.y), its end \(end())")
        XCTAssertGreaterThan(room, 1, "the transcript's padding leaves no room to scroll")
        if first {
            XCTAssertEqual(before, 0, "the fixture's block is on the screen already")
        } else {
            XCTAssertGreaterThan(before, 20, "the fixture's block is not on the screen")
        }
        let offset = scroll.contentOffset.y

        live.cue = CodeBlockCue(reply: reply.ref, number: 1, serial: 1)
        // Looked at every tenth of a second until the block has been seen and seen pulsing, for
        // up to ten seconds, so a slow runner is waited for and a block never scrolled to or never
        // pulsed is still seen not to be.
        // How far the transcript moved is the most it was ever away from where it stood, read at
        // every look and for a second after, so a scroll there and back again is a move.
        // The pulse is drawn over the enclosure's outline and covers its ink while it breathes, so
        // a block on the screen is its outline, its pulse or some of each, and it is shown by both.
        var shown = 0, pulsed = 0, moved: CGFloat = 0
        try stage.poll { [self] in
            moved = max(moved, abs(scroll.contentOffset.y - offset))
            let drawn = try Pixels(stage.image(), blank: true)
            let ring = pulsing(drawn, rows: 0...drawn.height)
            shown = max(shown, drawn.count(outline) + ring)
            pulsed = max(pulsed, ring)
            return shown > 20 && pulsed > 20
        }
        stage.poll(for: 1) {
            moved = max(moved, abs(scroll.contentOffset.y - offset))
            return false
        }
        return (shown, pulsed, moved)
    }

    /// The transcript's scroll view, the first under `view`.
    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }

    /// A row first made with its block's cue already set — as a lazy stack makes the row it is
    /// scrolled to — pulses the block as it appears, though its cue never changed under it.
    func testABlockMadeWithItsCueAlreadySetPulsesAsItAppears() throws {
        var look = look(.phone)
        look.markdown.codePulse.accent = Color(pulseInk)
        look.markdown.codePulse.opacity = 1
        look.markdown.codePulse.width = 3
        // As slow as a breath can be, so a runner slow to draw still finds the pulse under way.
        look.markdown.codePulse.cycle = 5
        let reply = turn(.assistant, "Here:\n\n```\nlet x = 1\n```")
        let live = LiveCue()
        live.made = false
        live.cue = CodeBlockCue(reply: reply.ref, number: 1, serial: 1)
        let stage = try LiveStage(LiveRow(turn: reply, live: live, size: self.stage,
                                          padding: look.transcript.horizontalPadding), look: look, size: self.stage)
        defer { stage.close() }
        stage.wait(0.3)
        live.made = true
        var pulsed = 0
        try stage.poll { [self] in
            let drawn = try Pixels(stage.image())
            pulsed = max(pulsed, pulsing(drawn, rows: 0...drawn.height))
            return pulsed > 20
        }
        XCTAssertGreaterThan(pulsed, 20, "the block appeared under its cue and did not pulse")
    }

    /// The breath is eased the whole way and happens twice: it starts and ends at nothing, peaks
    /// at the middle of each breath, and never jumps — a pulse, not a flash.
    func testThePulseBreathesTwiceWithNoJump() {
        let pulse = Look.Markdown.Pulse()
        XCTAssertEqual(Look.Markdown.Pulse.cycles, 2)
        XCTAssertLessThan(pulse.opacity, 1, "the peak is opaque, which is a flash")
        XCTAssertGreaterThanOrEqual(pulse.cycle, 1.2, "a breath this quick reads as a flash")
        let step = 0.001
        var levels: [Double] = []
        var time = -0.1
        while time <= pulse.duration + 0.1 { levels.append(pulse.level(at: time)); time += step }
        XCTAssertEqual(levels.first, 0)
        XCTAssertEqual(levels.last, 0)
        let jump = zip(levels, levels.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertLessThanOrEqual(jump, .pi * step / pulse.cycle + 1e-9, "the outline jumps \(jump) in a millisecond")
        let peaks = (1..<(levels.count - 1)).filter { i in
            levels[i - 1] < levels[i] && levels[i] >= levels[i + 1] && levels[i] > 0.99
        }
        XCTAssertEqual(peaks.count, 2, "not two breaths")
        XCTAssertEqual(pulse.level(at: pulse.cycle / 2), 1, accuracy: 1e-9)
    }

    /// How alike two masks are, their top-left corners aligned: the pixels inked in both over
    /// those inked in either.
    private static func overlap(_ a: [[Bool]], _ b: [[Bool]]) -> Double {
        var both = 0, either = 0
        for y in 0..<max(a.count, b.count) {
            for x in 0..<max(a.first?.count ?? 0, b.first?.count ?? 0) {
                let inA = y < a.count && x < a[y].count && a[y][x]
                let inB = y < b.count && x < b[y].count && b[y][x]
                if inA && inB { both += 1 }
                if inA || inB { either += 1 }
            }
        }
        return either == 0 ? 0 : Double(both) / Double(either)
    }

    /// A code line longer than the column stays in the column: the phone scrolls it inside its
    /// enclosure and the watch and the television wrap it, and on every screen the enclosure
    /// ends where the reply's words end, before Topo's margin.
    func testALongCodeLineStaysInTheColumn() throws {
        for screen in Look.Screen.allCases {
            let look = look(screen)
            let pixels = try draw(turn(.assistant, long), look)
            let columns = try XCTUnwrap(pixels.columns(outline), "\(screen): no enclosure")
            let edge = (stage.width - look.transcript.horizontalPadding - look.transcript.replyTrailingInset) * pixels.scale
            XCTAssertLessThanOrEqual(CGFloat(columns.upperBound), edge + 1, "\(screen): the fence ran past the column")
            XCTAssertGreaterThanOrEqual(CGFloat(columns.lowerBound), look.transcript.horizontalPadding * pixels.scale - 1,
                                        "\(screen): the fence ran before the column")
        }
    }

    /// Wrapping a long line makes the block taller than scrolling it: the look's overflow is
    /// what decides, and both are drawn.
    func testTheOverflowIsTheLooks() throws {
        var scroll = look(.phone)
        scroll.markdown.codeOverflow = .scroll
        var wrap = scroll
        wrap.markdown.codeOverflow = .wrap
        let scrolled = try XCTUnwrap(try draw(turn(.assistant, long), scroll).rows(outline))
        let wrapped = try XCTUnwrap(try draw(turn(.assistant, long), wrap).rows(outline))
        XCTAssertGreaterThan(wrapped.count, scrolled.count * 2, "wrapping did not wrap: \(scrolled) \(wrapped)")
    }

    /// Emphasis, strong and inline code are drawn, not only carried: each is a different picture
    /// from the same word plain, through the renderer that reads Topo's lines.
    func testEmphasisAndInlineCodeDraw() throws {
        for screen in Look.Screen.allCases {
            let plain = try draw(turn(.assistant, "a word here"), look(screen))
            let again = try draw(turn(.assistant, "a word here"), look(screen))
            XCTAssertFalse(try LookStage.differ(plain.bytes, again.bytes), "\(screen): one row drew two pictures")
            for styled in ["a *word* here", "a **word** here", "a `word` here", "a ~~word~~ here"] {
                let drawn = try draw(turn(.assistant, styled), look(screen))
                XCTAssertTrue(try LookStage.differ(plain.bytes, drawn.bytes), "\(screen): \(styled) drew as plain")
            }
        }
    }

    /// A heading is drawn taller than the same words as a paragraph in Topo's turn, and in the
    /// person's the markup is drawn as typed: the same height as the words without it, and a
    /// different picture, since the `#` is there.
    func testAHeadingIsTallerAndThePersonsTurnIsLiteral() throws {
        for screen in Look.Screen.allCases {
            let look = look(screen)
            let words = try XCTUnwrap(try draw(turn(.assistant, "Reading the log"), look).inked, "\(screen)")
            let heading = try XCTUnwrap(try draw(turn(.assistant, "# Reading the log"), look).inked, "\(screen)")
            XCTAssertGreaterThan(heading.count, words.count, "\(screen): the heading is no taller than words")

            let typed = try draw(turn(.person, "# Reading *the* log"), look)
            let plain = try draw(turn(.person, "Reading the log"), look)
            XCTAssertEqual(try XCTUnwrap(typed.inked).count, try XCTUnwrap(plain.inked).count, accuracy: 2,
                           "\(screen): the person's markup changed their turn's height")
            XCTAssertTrue(try LookStage.differ(typed.bytes, plain.bytes), "\(screen): the person's markup was not drawn")
        }
    }

    // MARK: Quotes

    /// A quote is drawn behind one bar for each level it sits inside, each `quoteIndent` from the
    /// next, and its words start after the last of them: `> > b` draws two bars where `> a` draws
    /// one, on every screen.
    func testEachQuoteLevelDrawsItsOwnBar() throws {
        for screen in Look.Screen.allCases {
            let look = look(screen)
            let width = look.markdown.quoteBarWidth
            let step = width + look.markdown.quoteIndent

            let one = try draw(turn(.assistant, "> a quote"), look)
            let bars = try XCTUnwrap(one.runs(barInk), "\(screen): no bar at all")
            XCTAssertEqual(bars.count, 1, "\(screen): one level drew \(bars.count) bars")

            let two = try draw(turn(.assistant, "> > a quote"), look)
            let nested = try XCTUnwrap(two.runs(barInk), "\(screen): no bar in a nested quote")
            XCTAssertEqual(nested.count, 2, "\(screen): two levels drew \(nested.count) bars: \(nested)")
            for (level, run) in nested.enumerated() {
                XCTAssertEqual(CGFloat(run.count) / one.scale, width, accuracy: 1,
                               "\(screen): bar \(level) is not \(width) points wide")
            }
            XCTAssertEqual(CGFloat(nested[1].lowerBound - nested[0].lowerBound) / one.scale, step, accuracy: 1,
                           "\(screen): the second bar is not \(step) points after the first")
            XCTAssertEqual(CGFloat(nested[0].lowerBound - bars[0].lowerBound) / one.scale, 0, accuracy: 1,
                           "\(screen): the outer bar moved")

            // The words come after the last bar, one step further in than at one level.
            let near = try XCTUnwrap(one.columns(quoteInk), "\(screen): the quote's words were not drawn")
            let far = try XCTUnwrap(two.columns(quoteInk), "\(screen): the nested quote's words were not drawn")
            XCTAssertEqual(CGFloat(far.lowerBound - near.lowerBound) / one.scale, step, accuracy: 2,
                           "\(screen): the nested quote's words did not move in by \(step)")
        }
    }

    /// Three levels under a look whose bars and insets are far wider than the default: the bars are
    /// drawn at their width and the words are still inside the reply's column, as a long code line
    /// is. The top of both ranges (64 points each) spends more than a phone's column on three
    /// levels of bar, so what is held here is a look well above the default rather than its ceiling.
    func testADeepQuoteUnderAWideLookStaysInTheColumn() throws {
        var look = look(.phone)
        look.markdown.quoteBarWidth = 8
        look.markdown.quoteIndent = 16
        let pixels = try draw(turn(.assistant, "> > > deep"), look)
        let bars = try XCTUnwrap(pixels.runs(barInk), "no bars")
        XCTAssertEqual(bars.count, 3, "three levels drew \(bars.count) bars: \(bars)")
        let words = try XCTUnwrap(pixels.columns(quoteInk), "the deep quote's words were not drawn")
        let edge = (stage.width - look.transcript.horizontalPadding - look.transcript.replyTrailingInset) * pixels.scale
        XCTAssertLessThanOrEqual(CGFloat(words.upperBound), edge + 1, "the words ran past the column")
        XCTAssertGreaterThanOrEqual(CGFloat(words.lowerBound),
                                    (look.transcript.horizontalPadding + 3 * (8 + 16)) * pixels.scale - 2,
                                    "the words did not clear the bars")
    }

    /// A quote holds whatever markdown puts in it, and each of those keeps its bar: a heading and a
    /// fence inside a quote are drawn behind one, and the fence keeps its own enclosure inside the
    /// column — on the phone, where it is a horizontal scroller, as on the screens that wrap it.
    func testAQuotedHeadingAndFenceKeepTheirBar() throws {
        for screen in Look.Screen.allCases {
            let look = look(screen)
            let heading = try draw(turn(.assistant, "> # a head"), look)
            XCTAssertNotNil(heading.runs(barInk), "\(screen): a quoted heading drew no bar")

            let quoted = try draw(turn(.assistant, "> ```\n> let x = 1\n> ```"), look)
            let bars = try XCTUnwrap(quoted.runs(barInk), "\(screen): a quoted fence drew no bar")
            XCTAssertEqual(bars.count, 1, "\(screen): a quoted fence drew \(bars.count) bars")
            let enclosure = try XCTUnwrap(quoted.columns(outline), "\(screen): a quoted fence drew no enclosure")
            let edge = (stage.width - look.transcript.horizontalPadding - look.transcript.replyTrailingInset) * quoted.scale
            XCTAssertLessThanOrEqual(CGFloat(enclosure.upperBound), edge + 1, "\(screen): the quoted fence ran past the column")

            // And it is no narrower than the bare fence less the bar and its inset, so a scroller
            // squeezed to nothing inside the bars fails rather than passes.
            let bare = try XCTUnwrap(try draw(turn(.assistant, "```\nlet x = 1\n```"), look).columns(outline),
                                     "\(screen): no bare enclosure")
            let step = (look.markdown.quoteBarWidth + look.markdown.quoteIndent) * quoted.scale
            XCTAssertGreaterThanOrEqual(CGFloat(enclosure.count), CGFloat(bare.count) - step - 2,
                                        "\(screen): the quoted fence lost more width than the bar it stands behind")
        }
    }

    /// A quote and a list interleaved. Every bar of one quote stands in one column however deeply
    /// the list inside it nests, and a quote inside a list item keeps the item's indent.
    func testAQuoteAndAListInterleave() throws {
        for screen in Look.Screen.allCases {
            let look = look(screen)
            let indent = look.markdown.listIndent
            let margin = look.transcript.horizontalPadding

            // A nested list inside one quote: one bar, one column, both rows.
            let inQuote = try draw(turn(.assistant, "> - a\n>   - b"), look)
            let bars = try XCTUnwrap(inQuote.runs(barInk), "\(screen): a quoted list drew no bar")
            XCTAssertEqual(bars.count, 1, "\(screen): the bars of one quote stood in \(bars.count) columns: \(bars)")
            XCTAssertEqual(CGFloat(bars[0].lowerBound) / inQuote.scale, margin, accuracy: 1,
                           "\(screen): the bar of a quoted list is not at the margin")

            // A quote inside a list item keeps the item's indent, so its bar sits one indent in.
            let inItem = try draw(turn(.assistant, "- an item\n\n  > a quote"), look)
            let itemBars = try XCTUnwrap(inItem.runs(barInk), "\(screen): a quote in an item drew no bar")
            XCTAssertEqual(itemBars.count, 1, "\(screen): a quote in an item drew \(itemBars.count) columns of bar")
            XCTAssertEqual(CGFloat(itemBars[0].lowerBound) / inItem.scale, margin + indent, accuracy: 1,
                           "\(screen): the quote in an item did not keep the item's indent")

            // A list item inside a quote puts its marker after the bar, and the bar at the margin.
            let itemInQuote = try draw(turn(.assistant, "> - i"), look)
            let quoteBars = try XCTUnwrap(itemInQuote.runs(barInk), "\(screen): a quoted item drew no bar")
            XCTAssertEqual(quoteBars.count, 1, "\(screen): a quoted item drew \(quoteBars.count) columns of bar")
            XCTAssertEqual(CGFloat(quoteBars[0].lowerBound) / itemInQuote.scale, margin, accuracy: 1,
                           "\(screen): a quoted item's bar is not at the margin")
        }
    }

    /// A rendered stage as bytes, with the questions worth asking of it.
    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat

        @MainActor init(_ image: UIImage, blank: Bool = false) throws {
            bytes = try LookStage.bytes(image, blank: blank)
            let cgImage = try XCTUnwrap(image.cgImage)
            width = cgImage.width
            height = cgImage.height
            scale = CGFloat(width) / image.size.width
        }

        private func matches(_ colour: UIColor, _ index: Int) -> Bool {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colour.getRed(&r, green: &g, blue: &b, alpha: &a)
            let want = [r, g, b].map { Int($0 * 255 + 0.5) }
            return (0..<3).allSatisfy { abs(Int(bytes[index + $0]) - want[$0]) <= 6 }
        }

        func count(_ colour: UIColor) -> Int {
            stride(from: 0, to: bytes.count, by: 4).filter { matches(colour, $0) }.count
        }

        /// The columns a colour is found in, first to last.
        func columns(_ colour: UIColor) -> ClosedRange<Int>? {
            var found: [Int] = []
            for y in 0..<height { for x in 0..<width where matches(colour, (y * width + x) * 4) { found.append(x) } }
            guard let low = found.min(), let high = found.max() else { return nil }
            return low...high
        }

        /// The disjoint column runs a colour is found in, leading first: one per bar, so two bars
        /// are two runs and one bar of twice the width is one.
        func runs(_ colour: UIColor) -> [ClosedRange<Int>]? {
            var found: Set<Int> = []
            for y in 0..<height { for x in 0..<width where matches(colour, (y * width + x) * 4) { found.insert(x) } }
            guard !found.isEmpty else { return nil }
            var runs: [ClosedRange<Int>] = []
            for x in found.sorted() {
                if let last = runs.last, x == last.upperBound + 1 { runs[runs.count - 1] = last.lowerBound...x }
                else { runs.append(x...x) }
            }
            return runs
        }

        /// The disjoint row runs a colour is found in, top first: one per enclosure.
        func rowRuns(_ colour: UIColor) -> [ClosedRange<Int>]? {
            let found = (0..<height).filter { y in (0..<width).contains { matches(colour, (y * width + $0) * 4) } }
            guard !found.isEmpty else { return nil }
            var runs: [ClosedRange<Int>] = []
            for y in found {
                if let last = runs.last, y == last.upperBound + 1 { runs[runs.count - 1] = last.lowerBound...y }
                else { runs.append(y...y) }
            }
            return runs
        }

        /// The caption ink's pixels in a region, cropped to where they are: anything drawn in it
        /// on white, antialiased edges included, since the ink has no blue and white is all blue.
        /// Nil when there are none.
        func mask(rows: Range<Int>, columns: ClosedRange<Int>) -> [[Bool]]? {
            let inked = { (x: Int, y: Int) in
                let i = (y * width + x) * 4
                return bytes[i + 2] < 128 && bytes[i] > 200
            }
            let ys = rows.filter { y in columns.contains { inked($0, y) } }
            let xs = columns.filter { x in rows.contains { inked(x, $0) } }
            guard let top = ys.first, let bottom = ys.last, let left = xs.first, let right = xs.last else {
                return nil
            }
            return (top...bottom).map { y in (left...right).map { inked($0, y) } }
        }

        /// How many pixels of a colour run from `x` rightward along row `y`.
        func run(_ colour: UIColor, row y: Int, from x: Int) -> Int {
            var n = 0
            while x + n < width, matches(colour, (y * width + x + n) * 4) { n += 1 }
            return n
        }

        /// The rows a colour is found in, first to last.
        func rows(_ colour: UIColor) -> ClosedRange<Int>? {
            let found = (0..<height).filter { y in (0..<width).contains { matches(colour, (y * width + $0) * 4) } }
            guard let low = found.first, let high = found.last else { return nil }
            return low...high
        }

        /// The rows anything but white is drawn in, first to last.
        var inked: ClosedRange<Int>? {
            let found = (0..<height).filter { y in
                (0..<width).contains { x in (0..<3).contains { bytes[(y * width + x) * 4 + $0] < 200 } }
            }
            guard let low = found.first, let high = found.last else { return nil }
            return low...high
        }
    }
}

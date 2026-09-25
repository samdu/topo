import SwiftUI
#if os(iOS)
import TopoMascot
#endif

/// Where the things are that Topo stands clear of, reported by the views that draw them: the
/// transcript's frame, which is where he may stand, every turn, the row being written and the
/// lines under the transcript, which he may not cover, and the composer's pane and well, which he
/// is never drawn over.
///
/// Each is an anchor, resolved where he is drawn (`mascotRoams`), so the frames are the ones
/// drawn and not ones worked out: a turn scrolled half out of sight is where it is drawn.
struct MascotScene: PreferenceKey {
    struct Value {
        var visible: Anchor<CGRect>?
        var pane: Anchor<CGRect>?
        var well: Anchor<CGRect>?
        /// Each view's frames: one for most, a line each for words with nothing drawn round them.
        var obstacles: [Anchor<[CGRect]>] = []
    }

    static let defaultValue = Value()

    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value.visible = value.visible ?? next.visible
        value.pane = value.pane ?? next.pane
        value.well = value.well ?? next.well
        value.obstacles += next.obstacles
    }
}

extension View {
    /// Something Topo may not be drawn over: a turn, the row being written, a line under the
    /// transcript. Every platform's transcript reports its turns; only the phone reads them.
    func mascotObstacle(_ reported: Bool = true) -> some View {
        transformAnchorPreference(key: MascotScene.self, value: Anchor<[CGRect]>.Source([.bounds])) {
            if reported { $0.obstacles.append($1) }
        }
    }

    /// Words Topo may not be drawn over, reported a line at a time where the lines can be read, so
    /// the room after a short line — the last of a long reply, the end of a paragraph — is room.
    /// Where they cannot, the words' frame, which is as wide as the widest line.
    func mascotLines(_ reported: Bool = true) -> some View {
        modifier(MascotLines(reported: reported))
    }

    /// The frame Topo may stand in: the transcript's.
    func mascotVisible() -> some View {
        transformAnchorPreference(key: MascotScene.self, value: .bounds) { $0.visible = $1 }
    }

    /// The composer's pane, which he is never drawn over.
    func mascotPane() -> some View {
        transformAnchorPreference(key: MascotScene.self, value: .bounds) { $0.pane = $1 }
    }

    /// The composer's well, which he is never drawn over.
    func mascotWell() -> some View {
        transformAnchorPreference(key: MascotScene.self, value: .bounds) { $0.well = $1 }
    }
}

/// Reports a text's lines as it lays them out. `Text.Layout` is read by a `TextRenderer`, which
/// is handed it at drawing time and nowhere else (iOS 18); the lines it read are kept here and
/// reported as rects in the text's own space, and until they have been read, or on iOS 17, the
/// text's whole frame is.
private struct MascotLines: ViewModifier {
    let reported: Bool
    @State private var lines: [CGRect] = []

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 18, watchOS 11, tvOS 18, macOS 15, *) {
                content.textRenderer(LineReader { read in if read != lines { lines = read } })
            } else {
                content
            }
        }
        .transformAnchorPreference(key: MascotScene.self,
                                   value: Anchor<[CGRect]>.Source(lines.isEmpty ? [.bounds] : lines.map { .rect($0) })) {
            if reported { $0.obstacles.append($1) }
        }
    }
}

/// Draws a text as it would be drawn anyway, and hands its lines' typographic bounds to `read`
/// on the main actor. A line with no width (an empty one between paragraphs) is nothing to
/// stand clear of and is left out.
@available(iOS 18, watchOS 11, tvOS 18, macOS 15, *)
private struct LineReader: TextRenderer {
    let read: @MainActor ([CGRect]) -> Void

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var rects: [CGRect] = []
        for line in layout {
            context.draw(line)
            let rect = line.typographicBounds.rect
            if rect.width > 0, rect.height > 0 { rects.append(rect) }
        }
        let read = read
        DispatchQueue.main.async { read(rects) }
    }
}

#if os(iOS)
/// The part of the engine's 184×160 picture he takes up at rest, in art pixels: the union of what he
/// draws sitting on the shelf at home — breathing, blinking, looking about, his arms drifting — on
/// every head and load band and in both facings, with two pixels round it. Facing right the engine
/// mirrors the picture about his body's axis (x = `Topo.bodyX`), so the union of the two is
/// symmetric about that axis: the box, and the reach below, are the same in either facing and his
/// body stands at the same point of the screen whichever way he faces
/// (`MascotGeometryTests.testHeRestsInsideTheBox` runs the idle state and holds that nothing is drawn
/// outside it). The box is what a gap has to hold, what the roost and the hurry judge and what
/// "covered" means. The canvas draws the whole picture round it, so an excursion, a working pose or
/// the sign reaches past the box and over whatever is there, and that reach is nothing the roam
/// answers: they are brief, and he comes back to the box. What it answers of that reach is the
/// screen's edge, the composer's pane and well and the keyboard: `reach` keeps the whole of it
/// inside the transcript's frame and off all three.
enum MascotSprite {
    static let box = CGRect(x: 33, y: 67, width: 94, height: 89)

    /// The part of the picture he can be drawn in at all, in art pixels: the union of every pose
    /// the app can ask the engine for — the idle cycle with its corner and yoga, the walk, and
    /// thinking, searching, building, writing and calendar, on every head and load band, and the
    /// ways between them — in both facings, with two pixels round it
    /// (`MascotGeometryTests.testEveryPoseTheAppAsksForIsDrawnInsideTheReach`). Facing right what a
    /// pose reaches on his right is reached on his left, so each side is the longer of the two.
    /// The sign is not in it, because nothing in the app sets one (`MascotState.sign`); a sign
    /// reaches about 40 pixels further out on the side he faces.
    static let reach = CGRect(x: 15, y: 47, width: 130, height: 113)

    /// How far `reach` goes past the box on each side, in points at `scale`.
    struct Reach: Equatable, Sendable {
        var left: CGFloat = 0, top: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0

        static let none = Reach()

        /// The same on every side.
        static func all(_ length: CGFloat) -> Reach { Reach(left: length, top: length, right: length, bottom: length) }

        /// Each side the longer of this and `other`.
        func union(_ other: Reach) -> Reach {
            Reach(left: max(left, other.left), top: max(top, other.top), right: max(right, other.right),
                  bottom: max(bottom, other.bottom))
        }

        /// `frame` grown by this on each side.
        func around(_ frame: CGRect) -> CGRect {
            CGRect(x: frame.minX - left, y: frame.minY - top, width: frame.width + left + right,
                   height: frame.height + top + bottom)
        }
    }

    static func reach(scale: CGFloat) -> Reach {
        Reach(left: (box.minX - reach.minX) * scale, top: (box.minY - reach.minY) * scale,
              right: (reach.maxX - box.maxX) * scale, bottom: (reach.maxY - box.maxY) * scale)
    }

    /// His picture on the screen, in points, at `scale` points an art pixel.
    static func size(scale: CGFloat) -> CGSize {
        CGSize(width: box.width * scale, height: box.height * scale)
    }

    /// The whole of the engine's picture on the screen, for the box drawn at `picture`.
    static func drawn(around picture: CGRect) -> CGRect {
        let scale = picture.width / box.width
        return CGRect(x: picture.minX - box.minX * scale, y: picture.minY - box.minY * scale,
                      width: CGFloat(Topo.width) * scale, height: CGFloat(Topo.height) * scale)
    }
}

/// The chat's geometry as Topo reads it, in the space he is drawn in.
struct MascotField: Equatable, Sendable, Codable {
    /// The transcript's frame: where he may stand.
    var visible: CGRect
    /// What he may not be drawn over: every turn, the row being written, the lines under the
    /// transcript, the offer card.
    var obstacles: [CGRect] = []
    /// The composer's pane and its well; nil where there is none.
    var pane: CGRect?
    var well: CGRect?
    /// The keyboard, while it is up.
    var keyboard: CGRect?

    /// What a pin is a fraction of: the transcript's frame, carried down to the pane's foot where
    /// the pane is below it, since the lines under the transcript and the glass are part of the
    /// chat a person can put him over — the well included, which keeps its press whatever is drawn
    /// over it.
    var pinFrame: CGRect {
        guard let pane, pane.maxY > visible.maxY else { return visible }
        return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: pane.maxY - visible.minY)
    }

    /// Where a gap can be: the transcript's frame down to the pane's top edge and the keyboard's.
    /// Text runs under the pane, but the pane is glass over it and not text, so what is under the
    /// pane is not what he covers; beside the pane is left out with it, which only costs him room.
    var open: CGRect {
        var bottom = visible.maxY
        if let pane { bottom = min(bottom, pane.minY) }
        if let keyboard { bottom = min(bottom, keyboard.minY) }
        guard bottom > visible.minY else { return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: 0) }
        return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: bottom - visible.minY)
    }

    /// Where his box can be, for a picture reaching `reach` past it: `open`, drawn in by the reach
    /// from the transcript's edges and from the pane's top edge and the keyboard's, so nothing he
    /// can be drawn in is cut by the screen's edge or reaches onto the glass. What he keeps from
    /// the words is the box's clearance, and nothing more.
    func room(_ reach: MascotSprite.Reach) -> CGRect {
        let open = open
        let minX = visible.minX + max(reach.left, 0), maxX = visible.maxX - max(reach.right, 0)
        let minY = visible.minY + max(reach.top, 0), maxY = open.maxY - max(reach.bottom, 0)
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }

    /// Where an obstacle can be seen: from the transcript's top edge — above it is the navigation
    /// bar, which a turn scrolls under — down to the pane's top edge and the keyboard's, and as
    /// wide as anything is. The lines under the transcript and the offer card are in it; a turn
    /// under the glass is not.
    var seen: CGRect {
        var bottom = CGFloat.greatestFiniteMagnitude / 4
        if let pane { bottom = min(bottom, pane.minY) }
        if let keyboard { bottom = min(bottom, keyboard.minY) }
        let wide = CGFloat.greatestFiniteMagnitude / 4
        return CGRect(x: -wide, y: visible.minY, width: 2 * wide, height: max(bottom - visible.minY, 0))
    }

    /// What he may not be drawn over: what of each obstacle can be seen (`seen`); the composer's
    /// pane and its well, whole, at every presence and whether the keyboard is up or down, since
    /// the glass is the controls' and never his; and the keyboard, whose keys are words too.
    var covering: [CGRect] {
        let seen = seen
        var all = obstacles.map { $0.intersection(seen) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        if let pane { all.append(pane) }
        if let well { all.append(well) }
        if let keyboard { all.append(keyboard) }
        return all
    }

    /// What he is never drawn over, even in passing: the composer's pane and well and the keyboard.
    /// A turn or a line he may cross at the hurry; these he goes round.
    var offLimits: [CGRect] {
        [pane, well, keyboard].compactMap { $0 }
    }

    /// What he keeps from each thing he may not cover, side by side of his box: `clearance` from
    /// the words; from the pane, the well and the keyboard, the clearance or his reach, whichever
    /// is longer on that side, since no pose of his is ever drawn over them.
    func kept(clearance: CGFloat, reach: MascotSprite.Reach) -> [(rect: CGRect, keep: MascotSprite.Reach)] {
        let words = MascotSprite.Reach.all(clearance)
        let seen = seen
        var all = obstacles.map { $0.intersection(seen) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            .map { (rect: $0, keep: words) }
        for limit in offLimits { all.append((rect: limit, keep: words.union(reach))) }
        return all
    }

    /// Whether his picture, `size` big and reaching `reach` past its box, crosses anything off
    /// limits on the straight way from one origin to another, judged every point of the way.
    func crossesOffLimits(from: CGPoint, to: CGPoint, size: CGSize, reach: MascotSprite.Reach = .none) -> Bool {
        let limits = offLimits
        guard !limits.isEmpty else { return false }
        let steps = max(Int((hypot(to.x - from.x, to.y - from.y)).rounded(.up)), 1)
        for step in 0...steps {
            let u = CGFloat(step) / CGFloat(steps)
            let frame = reach.around(CGRect(x: from.x + (to.x - from.x) * u, y: from.y + (to.y - from.y) * u,
                                            width: size.width, height: size.height))
            if limits.contains(where: { MascotRoost.overlap($0, frame) }) { return true }
        }
        return false
    }

    /// How far the words have moved down the screen since `previous`, in points: the transcript's
    /// scroll between two geometries, up negative, as far as the layout moved them and unrounded,
    /// so a drag of a tenth of a point a geometry adds up to what it moved. A scroll moves the
    /// words and nothing else, so a geometry whose transcript frame, pane, well or keyboard moved
    /// — the keyboard rising, the glass going short — is not one, and is no move.
    ///
    /// Each obstacle is paired with every one of the same place across and the same size in
    /// `previous`. One standing where one of its size stood has not moved and has no say in how
    /// far the rest did; each of the others votes for every move it could have made, and the move
    /// most of them agree on is the answer, the smallest of equals: the lines of a reply are alike
    /// and a line apart, and only the true move pairs every one of them. A move is outvoted by
    /// more obstacles that stood still than agree on it — a still page with a line added to a
    /// reply, which pairs with the reply's other lines, is no move — and a tie goes to the move,
    /// so one bubble scrolling past a still obstacle of its size is a scroll. Nothing paired is
    /// no move.
    func drift(since previous: MascotField) -> CGFloat {
        guard visible == previous.visible, pane == previous.pane, well == previous.well,
              keyboard == previous.keyboard else { return 0 }
        func key(_ rect: CGRect) -> [Int] {
            [Int((rect.minX * 2).rounded()), Int((rect.width * 2).rounded()), Int((rect.height * 2).rounded())]
        }
        var before: [[Int]: [CGFloat]] = [:]
        for rect in previous.obstacles where rect.width > 0 && rect.height > 0 { before[key(rect), default: []].append(rect.minY) }
        // Moves grouped in quarters of a point, the finest a screen's layout is laid out in; the
        // answer is the moves of the winning group as they were, averaged.
        var votes: [Int: (count: Int, sum: CGFloat)] = [:]
        var still = 0
        for rect in obstacles where rect.width > 0 && rect.height > 0 {
            let paired = before[key(rect)] ?? []
            if paired.contains(where: { abs(rect.minY - $0) <= Self.stillness }) {
                still += 1
                continue
            }
            for y in paired where abs(rect.minY - y) < Self.driftLimit {
                let move = rect.minY - y
                let vote = votes[Int((move * 4).rounded()), default: (0, 0)]
                votes[Int((move * 4).rounded())] = (vote.count + 1, vote.sum + move)
            }
        }
        guard let best = votes.max(by: { a, b in
            a.value.count < b.value.count || (a.value.count == b.value.count && abs(a.key) > abs(b.key))
        }), best.value.count >= still else { return 0 }
        return best.value.sum / CGFloat(best.value.count)
    }

    /// An obstacle within this of where one of its size stood has not moved.
    static let stillness: CGFloat = 0.001

    /// The most the words are taken to move between two geometries: more is not a scroll but a
    /// different page, and is no move.
    static let driftLimit: CGFloat = 400

    /// The word he is displaced by at `frame`: of the words within `clearance` of his box as far
    /// as they can be seen, the one over most of it; nil when no word is.
    func displacer(of frame: CGRect, clearance: CGFloat) -> CGRect? {
        let seen = seen
        let kept = frame.insetBy(dx: -clearance, dy: -clearance)
        return obstacles.map { $0.intersection(seen) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 && MascotRoost.overlap($0, kept) }
            .max { a, b in
                let x = a.intersection(kept), y = b.intersection(kept)
                return x.width * x.height < y.width * y.height
            }
    }

    /// Whether anything he may not cover overlaps his box at `frame`: a word over the box, or the
    /// pane, the well or the keyboard over anything his reach round it can be drawn in.
    func covers(_ frame: CGRect, reach: MascotSprite.Reach = .none) -> Bool {
        let seen = seen
        let words = obstacles.map { $0.intersection(seen) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        let reached = reach.around(frame)
        return words.contains { MascotRoost.overlap($0, frame) } || offLimits.contains { MascotRoost.overlap($0, reached) }
    }
}

/// Where Topo stands: a gap in the transcript, the glass, a pin, or nowhere.
enum MascotRoost: Equatable, Sendable {
    /// A gap in the transcript, and the frame of his picture in it.
    case gap(CGRect)
    /// The composer's empty flank, placed `glass`.
    case glass(CGRect)
    /// Where a person pinned him, placed `pinned`, or where a drag has him now.
    case pinned(CGRect)
    /// No gap holds him, and he is not drawn.
    case none

    var frame: CGRect? {
        switch self {
        case .gap(let frame), .glass(let frame), .pinned(let frame): frame
        case .none: nil
        }
    }

    var name: String {
        switch self {
        case .gap: "gap"
        case .glass: "glass"
        case .pinned: "pinned"
        case .none: "none"
        }
    }

    /// Where he stands, from the chat's geometry, the size of his picture, the room he keeps and
    /// where he stands now (`from`, his picture's origin; nil before he has stood anywhere).
    ///
    /// A gap is a place in `field.room(reach)` for his picture where it, with `clearance` all round it,
    /// overlaps nothing he may not cover. The clearance is kept from what he may not cover and
    /// not from the transcript's own edges, so the margin beside a reply holds him flush with the
    /// screen's edge. Of the gaps that hold him the nearest to `from` wins — so a new turn moves
    /// him the least — and with no `from` the nearest to the transcript's bottom trailing corner,
    /// the right margin just above the glass. With no gap he stands nowhere and is not drawn:
    /// never on the glass, never over the microphone.
    static func of(_ field: MascotField, size: CGSize, clearance: CGFloat, reach: MascotSprite.Reach = .none,
                   from: CGPoint?) -> MascotRoost {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return .none }
        let margin = clearance.isFinite ? max(clearance, 0) : 0
        let open = field.room(reach)
        let home = CGPoint(x: open.maxX - size.width, y: open.maxY - size.height)
        if let spot = nearestGap(field.kept(clearance: margin, reach: reach), open: open, size: size, to: from ?? home) {
            return .gap(CGRect(origin: spot, size: size))
        }
        return .none
    }

    /// The origin of his picture in the nearest gap to `target`, or nil for none.
    ///
    /// His box's origin is allowed anywhere that leaves the box inside `open`, the room, and the
    /// box, grown by what it keeps from each thing (`kept`), outside that thing; each thing so
    /// becomes a region of origins it forbids. The nearest
    /// allowed point to the target is the target itself or lies on the edge of one of those
    /// regions, at the target's own x or y or at a corner of two of them, so the lines through
    /// the target and every edge, crossed, hold it.
    private static func nearestGap(_ kept: [(rect: CGRect, keep: MascotSprite.Reach)], open: CGRect, size: CGSize,
                                   to target: CGPoint) -> CGPoint? {
        guard size.width <= open.width, size.height <= open.height else { return nil }
        let allowedX = open.minX...(open.maxX - size.width)
        let allowedY = open.minY...(open.maxY - size.height)
        let forbidden = kept.map { thing in
            CGRect(x: thing.rect.minX - size.width - thing.keep.right, y: thing.rect.minY - size.height - thing.keep.bottom,
                   width: thing.rect.width + size.width + thing.keep.left + thing.keep.right,
                   height: thing.rect.height + size.height + thing.keep.top + thing.keep.bottom)
        }
        let aim = target
        var xs = [aim.x.clamped(to: allowedX), allowedX.lowerBound, allowedX.upperBound]
        var ys = [aim.y.clamped(to: allowedY), allowedY.lowerBound, allowedY.upperBound]
        for region in forbidden {
            xs += [region.minX, region.maxX].filter(allowedX.contains)
            ys += [region.minY, region.maxY].filter(allowedY.contains)
        }
        var best: (point: CGPoint, distance: CGFloat)?
        for y in ys {
            for x in xs {
                let point = CGPoint(x: x, y: y)
                guard !forbidden.contains(where: { strictlyInside(point, $0) }) else { continue }
                let distance = hypot(x - aim.x, y - aim.y)
                if let best, !(distance < best.distance - epsilon
                               || (abs(distance - best.distance) <= epsilon && (-x, y) < (-best.point.x, best.point.y))) {
                    continue
                }
                best = (point, distance)
            }
        }
        return best?.point
    }

    /// Whether `frame` is a roost as it stands: a gap — inside `field.room(reach)`, with no word
    /// within `clearance` of it and neither the pane, the well nor the keyboard within that or his
    /// reach. The small-move threshold keeps him only where this holds.
    static func holds(_ field: MascotField, frame: CGRect, clearance: CGFloat, reach: MascotSprite.Reach = .none) -> Bool {
        let margin = clearance.isFinite ? max(clearance, 0) : 0
        guard field.room(reach).insetBy(dx: -epsilon, dy: -epsilon).contains(frame) else { return false }
        return !field.kept(clearance: margin, reach: reach).contains { overlap($0.rect, $0.keep.around(frame)) }
    }

    /// A thousandth of a point: what two edges that meet are allowed to share without counting as
    /// an overlap, since the edges are sums of floating-point sizes.
    static let epsilon: CGFloat = 0.001

    private static func strictlyInside(_ point: CGPoint, _ rect: CGRect) -> Bool {
        point.x > rect.minX + epsilon && point.x < rect.maxX - epsilon
            && point.y > rect.minY + epsilon && point.y < rect.maxY - epsilon
    }

    /// Two frames overlap when they share more than an edge.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX - epsilon && b.minX < a.maxX - epsilon
            && a.minY < b.maxY - epsilon && b.minY < a.maxY - epsilon
    }
}

/// Where Topo stands when the look places him rather than letting him roam: on the glass, or at a
/// pin. Pure functions of the chat's geometry, so each policy's answer is arithmetic a test holds.
enum MascotPerch {
    /// His box on the composer's glass, in its empty flank — the trailing one, since the leading
    /// flank holds the keyboard's control — with the engine's shelf on the pane's top edge and his
    /// body in the middle of the flank: from the well's trailing edge to the pane's trailing end.
    /// Nil where there is no pane or no well to stand beside.
    static func glass(_ field: MascotField, size: CGSize) -> CGRect? {
        guard let slot = glassSlot(field), let pane = field.pane, size.width > 0, size.height > 0 else { return nil }
        let scale = size.width / MascotSprite.box.width
        let top = pane.minY - (CGFloat(Topo.shelfY) - MascotSprite.box.minY) * scale
        return CGRect(x: slot.midX - size.width / 2, y: top, width: size.width, height: size.height)
    }

    /// The part of the chat he is drawn in while he stands on the glass: across, the empty flank
    /// from the well's trailing edge to the pane's trailing end, so no pose of his is drawn over
    /// the microphone or off the end of the pane; down, everything to the pane's foot.
    static func glassSlot(_ field: MascotField) -> CGRect? {
        guard let pane = field.pane, let well = field.well else { return nil }
        let left = min(well.maxX, pane.maxX)
        // Above the pane is as far up as the screen goes; a number any screen is inside, and small
        // enough that the pane's foot survives being added to it.
        let top = min(field.visible.minY, pane.minY) - 10_000
        return CGRect(x: left, y: top, width: pane.maxX - left, height: pane.maxY - top)
    }

    /// The view he is drawn in while he stands on the glass (`MascotGlassStage`): the whole
    /// picture drawn round his box on the pane, which SwiftUI places from the pane's own frame
    /// inside a clip of `glassSlot`, so where the pane is drawn — on the keyboard's curve as it
    /// rises and falls — he is drawn with it, and his picture fills the stage at every height.
    static func glassStage(_ field: MascotField, size: CGSize) -> CGRect? {
        glass(field, size: size).map(MascotSprite.drawn(around:))
    }

    /// His box at `pin`, a fraction of `frame` across and down, as the look carries it: the box's
    /// centre put there, then moved in only as far as it takes to keep his reach inside `frame` —
    /// the transcript's with the keyboard down — so the screen's edge holds him wherever the pin
    /// is. The pin is read in `0...1` here too, whatever it is handed. With the keyboard up he is
    /// lifted clear of it, keeping from its top edge his clearance or his reach, whichever is
    /// longer, and no further up than the transcript's top edge lets him: the pin is where he goes
    /// back to when it goes. The glass and the words are not obstacles, since a person put him
    /// there. Nil for a frame with no room at all.
    static func pinned(_ pin: CGPoint, in frame: CGRect, keyboard: CGRect?, size: CGSize,
                       reach: MascotSprite.Reach, clearance: CGFloat) -> CGRect? {
        guard frame.width > 0, frame.height > 0, frame.width.isFinite, frame.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let px = pin.x.isFinite ? pin.x.clamped(to: 0...1) : 0.5
        let py = pin.y.isFinite ? pin.y.clamped(to: 0...1) : 0.5
        let at = inside(CGRect(x: frame.minX + px * frame.width - size.width / 2,
                               y: frame.minY + py * frame.height - size.height / 2,
                               width: size.width, height: size.height), frame, reach: reach)
        let x = at.minX
        var y = at.minY
        if let keyboard {
            let keep = max(clearance.isFinite ? max(clearance, 0) : 0, reach.bottom)
            let lowest = keyboard.minY - keep - size.height
            if y > lowest { y = max(lowest, frame.minY + reach.top) }
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Where `frame`'s centre is, as a pin: a fraction of `within` across and down, each in `0...1`.
    static func pin(of frame: CGRect, in within: CGRect) -> CGPoint {
        guard within.width > 0, within.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: ((frame.midX - within.minX) / within.width).clamped(to: 0...1),
                       y: ((frame.midY - within.minY) / within.height).clamped(to: 0...1))
    }

    /// `box` moved in only as far as it takes to keep its reach inside `frame`: the screen's edge
    /// holding him, at a pin and in a finger alike.
    static func inside(_ box: CGRect, _ frame: CGRect, reach: MascotSprite.Reach) -> CGRect {
        CGRect(x: inside(box.minX, from: frame.minX + reach.left, to: frame.maxX - reach.right - box.width),
               y: inside(box.minY, from: frame.minY + reach.top, to: frame.maxY - reach.bottom - box.height),
               width: box.width, height: box.height)
    }

    /// `value` inside `from...to`, or halfway between them where the range is empty.
    private static func inside(_ value: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
        guard from <= to else { return (from + to) / 2 }
        return value.clamped(to: from...to)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

/// Topo's going from roost to roost, as a value moved on by the clock and told each new geometry,
/// so what he does over a stream of geometry is a thing a test can script.
///
/// Two decisions, kept apart. **Where to go** is made once the geometry holds still: `settle`
/// seconds of it with nothing changing, since the transcript reports its geometry on every frame
/// of a scroll — or a single frame of it while something is over him, so a covered Topo gets out
/// of the way as soon as the scroll or the landing turn stops rather than a settle later. It
/// is never made mid-move, and a roost within `clearance` of where he stands is not a move while
/// where he stands is a roost itself (`MascotRoost.holds`). A move is one eased glide at `speed` points a second on average — `hurry` times that on every frame
/// anything is over him, and back to the stroll the frame he is clear — which under Reduce Motion
/// is a placement with no glide.
///
/// A word that displaces him sends him to its far side from where it is going — under a word
/// moving up the screen or standing still, over one moving down — so it passes over him once
/// rather than pushing him ahead of it. Where a glide is going moves with the words as they
/// scroll (`MascotField.drift`), so a decision taken while they move is still a gap on the next
/// frame: one decision a crossing. With no room on the far side he goes to the near one and
/// rides the words (`riding`) until they stop or carry him to the edge of where he may stand. He is drawn above everything but the keyboard wherever he is, so
/// nothing is judged about whether he may be seen: he is drawn whenever he stands anywhere.
struct MascotRoam: Equatable, Sendable {
    struct Settings: Equatable, Sendable {
        var size: CGSize
        var clearance: CGFloat
        /// How far the picture he can be drawn in reaches past his box, which the transcript's
        /// edges hold.
        var reach: MascotSprite.Reach
        var speed: CGFloat
        var hurry: CGFloat
        var settle: Double
        var reduceMotion = false
        /// Where he sits, as a policy (`Look.Mascot.Placement`), and the pin he is put at while it
        /// is `pinned`.
        var placement = Look.Mascot.Placement.roam
        var pin = Look.Mascot().pin

        init(size: CGSize, clearance: CGFloat, reach: MascotSprite.Reach = .none, speed: CGFloat,
             hurry: CGFloat = 10, settle: Double, reduceMotion: Bool = false,
             placement: Look.Mascot.Placement = .roam, pin: CGPoint = Look.Mascot().pin) {
            self.size = size
            self.clearance = clearance
            self.reach = reach
            self.speed = speed
            self.hurry = hurry
            self.settle = settle
            self.reduceMotion = reduceMotion
            self.placement = placement
            self.pin = pin
        }

        init(_ mascot: Look.Mascot, reduceMotion: Bool) {
            self.init(size: MascotSprite.size(scale: mascot.scale), clearance: mascot.clearance,
                      reach: MascotSprite.reach(scale: mascot.scale), speed: mascot.roamSpeed, hurry: mascot.hurry, settle: mascot.roamSettle,
                      reduceMotion: reduceMotion, placement: mascot.placement, pin: mascot.pin)
        }

        /// The same policy and the same place: a change of either is a glide to where the new one
        /// puts him.
        func samePlace(as other: Settings) -> Bool {
            placement == other.placement && (placement != .pinned || pin == other.pin)
        }
    }

    /// One glide, from one picture origin to another, eased at both ends. `duration` is the
    /// glide at the stroll, and `elapsed` how far along it he is, in the stroll's seconds: a frame
    /// in a hurry moves it on by `hurry` frames' worth, so the ease is the same curve run faster.
    struct Move: Equatable, Sendable {
        var from: CGPoint
        var to: CGPoint
        var duration: Double
        var elapsed = 0.0
        /// How many times the stroll it goes at the least: 1, or the hurry for a pinned Topo the
        /// keyboard has come up over.
        var pace: CGFloat = 1

        /// Where he is `elapsed` stroll-seconds along it.
        func at(_ elapsed: Double) -> CGPoint {
            guard duration > 0 else { return to }
            let u = min(max(elapsed / duration, 0), 1)
            let eased = CGFloat((1 - cos(.pi * u)) / 2)
            return CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
        }

        var point: CGPoint { at(elapsed) }
        var done: Bool { elapsed >= duration }
    }

    var settings: Settings
    private(set) var field: MascotField?
    /// Where he is going, or standing.
    private(set) var roost: MascotRoost = .none
    /// Which way he faces, decided with each roost that is a gap (`MascotFacing.of`, his box's
    /// centre against the transcript's vertical midline) and kept while he stands nowhere. His box
    /// is symmetric about his body's axis, so its centre is where his body stands.
    private(set) var facing: MascotFacing = .left
    /// His picture's origin now; nil while he stands nowhere.
    private(set) var position: CGPoint?
    private(set) var move: Move?
    /// Something he may not cover overlaps him where he is now: a word his box, or the pane, the
    /// well or the keyboard his reach.
    private(set) var covered = false

    private var isCovered: Bool {
        guard settings.placement == .roam, !dragging, let picture, let field else { return false }
        return field.covers(picture, reach: settings.reach)
    }
    /// A finger has him: he goes where it takes him, and nothing is decided until it lets go.
    private(set) var dragging = false
    /// How many drags have begun, for the tests: a press that was not one leaves it alone.
    private(set) var drags = 0
    /// The frame a pin is a fraction of with the keyboard down (`MascotField.pinFrame`): the last
    /// of a geometry with no keyboard in it.
    private(set) var resting: CGRect?
    /// How many glides have begun, for the tests.
    private(set) var moves = 0
    /// Which way the words are moving, in points down the screen at the last geometry (up
    /// negative): none when that geometry moved nothing, and none once the geometry has settled.
    private(set) var heading: CGFloat = 0
    /// He was displaced to the side of a word it is moving toward — there was no room behind it —
    /// so he goes with the words until they stop, rather than being caught again and again.
    private(set) var riding = false
    /// The geometry changed since the roost was last decided.
    private(set) var unsettled = false
    /// When the geometry last changed, and when the roam was last moved on.
    private var changed = -Double.infinity
    private var now = 0.0
    /// When the clock last moved the glide on, which a geometry arriving between frames does not.
    private var advanced = 0.0
    /// The time a frame lasts, which is the quiet a covered Topo waits for.
    var frame: Double
    /// The transcript has not been read yet: the page is about to fill, so he stands nowhere and
    /// is not drawn until it has.
    private(set) var waiting = false

    /// `standing` is where his picture's origin is to begin with, which a replay of a recorded run
    /// starts from; nil, as the app has it, is nowhere.
    init(_ settings: Settings, frame: Double = 1.0 / 30, standing: CGPoint? = nil) {
        self.settings = settings
        self.frame = frame
        if let standing {
            position = standing
            roost = .gap(CGRect(origin: standing, size: settings.size))
        }
    }

    /// His picture where it is now; nil while he stands nowhere.
    var picture: CGRect? { position.map { CGRect(origin: $0, size: settings.size) } }
    /// He is not drawn: he stands nowhere.
    var hidden: Bool { position == nil }
    /// He is gliding, which is when he wears the walk.
    var walking: Bool { move != nil }
    /// There is something the clock has to move on: a glide, or a decision waiting on the quiet.
    var needsTime: Bool { move != nil || unsettled }

    /// The chat's geometry, as drawn now. Where he stands nowhere yet, the geometry that holds
    /// still for a settle places him with no glide, since there is nowhere to glide from: a chat
    /// still laying itself out — the glass rising into place as the screen appears — is not where
    /// he is put.
    ///
    /// Mid-glide, a geometry that leaves where he is going no roost, or puts the pane, the well or
    /// the keyboard on the rest of his way, is decided at once, with no settle: the glide turns
    /// from where he is to the new roost, at the hurry while anything is over him. A destination
    /// that still holds, with the way to it clear, keeps the glide. A geometry that leaves any of
    /// him below the pane's top edge or the keyboard's — the glass rising with the keyboard onto
    /// or past where he stands, which SwiftUI lays out in one step while the render server
    /// animates it across him — places him at once, with no glide, since a glide out from under
    /// the glass or the keyboard would draw him over the glass on its way; with nowhere to go he is
    /// not drawn.
    mutating func observe(_ field: MascotField, at time: Double) {
        now = max(now, time)
        guard field != self.field else { return }
        if field.keyboard == nil { resting = field.pinFrame }
        // A finger has him, or the look places him: the roam decides nothing.
        if dragging {
            self.field = field
            covered = false
            return
        }
        if settings.placement != .roam {
            let keyboardMoved = (self.field?.keyboard == nil) != (field.keyboard == nil)
            self.field = field
            changed = now
            // Not yet placed: the chat is still laying itself out, and he is placed once it has
            // held still for a settle after the read, as a roaming Topo is.
            guard position != nil else {
                unsettled = true
                return
            }
            perch(keyboardMoved ? .keyboard : .geometry)
            return
        }
        let drift = self.field.map { field.drift(since: $0) } ?? 0
        self.field = field
        changed = now
        unsettled = true
        // Which way the words are going is what this geometry moved them: none is a still page,
        // whatever the last scroll did.
        heading = drift
        let edge = drift != 0 && follow(drift, in: field)
        covered = isCovered
        // Riding the words to the edge of where he may stand is the end of the ride: he stops at
        // the edge, is drawn there and not past it, and decides a glide from inside his room.
        if edge {
            move = nil
            decide(glide: true)
            unsettled = true
            covered = isCovered
            return
        }
        if let picture, case let reached = settings.reach.around(picture),
           reached.maxY > field.open.maxY + MascotRoost.epsilon
            || [field.pane, field.well].contains(where: { $0.map { MascotRoost.overlap($0, reached) } ?? false }) {
            move = nil
            decide(glide: false)
            unsettled = true
            covered = isCovered
            return
        }
        if let move, let from = position {
            let destination = CGRect(origin: move.to, size: settings.size)
            if !MascotRoost.holds(field, frame: destination, clearance: settings.clearance, reach: settings.reach)
                || field.crossesOffLimits(from: from, to: move.to, size: settings.size, reach: settings.reach) {
                self.move = nil
                decide(glide: true)
                // A new roost within his clearance of where he was going is the same glide
                // carried on, since the words he goes between moved and not his mind: not counted
                // as another, and timed from where he is to where it now ends, so he does not jump
                // the difference in one frame.
                if let next = self.move, hypot(next.to.x - move.to.x, next.to.y - move.to.y) <= settings.clearance {
                    moves -= 1
                }
                // The geometry may still be moving: the settled decision follows as ever.
                unsettled = true
                covered = isCovered
            }
        }
    }

    /// Whether the transcript is still to be read. While it is, every decision is nowhere; once it
    /// has been, the geometry counts as changed then, so his first decision where to stand is a
    /// settle after the read.
    mutating func wait(_ waiting: Bool, at time: Double) {
        guard waiting != self.waiting else { return }
        now = max(now, time)
        self.waiting = waiting
        changed = now
        unsettled = true
        // A placed Topo is nowhere while the transcript is to be read, as a roaming one is.
        if waiting, settings.placement != .roam, !dragging {
            roost = .none
            position = nil
            move = nil
        }
    }

    /// The settings, which a look or Reduce Motion can change. Reduce Motion coming on ends a glide
    /// at its destination at once. A new size or clearance is a new answer to where he may stand,
    /// so it is decided at once, with no glide, whether he is standing or gliding: a glide under
    /// the old values goes to a roost the new ones may refuse — a larger picture across the well,
    /// a clearance a turn is inside — and he is never drawn at a size no roost was decided for.
    mutating func use(_ settings: Settings) {
        guard settings != self.settings else { return }
        let reroost = settings.size != self.settings.size || settings.clearance != self.settings.clearance
            || settings.reach != self.settings.reach
        let switched = !settings.samePlace(as: self.settings)
        self.settings = settings
        if settings.reduceMotion, let move {
            position = move.to
            self.move = nil
        }
        // Held by a finger, he is where it has him; what it lets go of is decided then.
        if dragging { return }
        // A new policy, or a new pin, is a glide from where he stands to where it puts him, at the
        // stroll, as a roost change is; from a pin to roaming, a roost is decided from where he
        // stands. A new size or clearance under a placed policy places him at once, as it does
        // when he roams. Not yet placed, he is placed at the settle.
        if settings.placement != .roam, switched || reroost {
            guard position != nil else {
                changed = now
                unsettled = true
                return
            }
            perch(reroost ? .atOnce : .switched)
            return
        }
        if switched, position != nil {
            move = nil
            decide(glide: !reroost)
            unsettled = true
            covered = isCovered
            return
        }
        if reroost, position != nil {
            move = nil
            decide(glide: false)
        } else if reroost || switched {
            // Not drawn: the new size may fit where the old did not, decided once it settles.
            changed = now
            unsettled = true
        }
        covered = isCovered
    }

    /// The clock at `time`: the glide moved on, whether he is covered judged where he now is, and
    /// the roost decided if the geometry has been quiet long enough.
    mutating func advance(to time: Double) {
        let dt = max(time - advanced, 0)
        advanced = max(advanced, time)
        now = max(now, time)
        if var move {
            // The pace this frame is judged where he was over it: in a hurry while covered, and
            // never under the glide's own.
            move.elapsed += dt * Double(max(covered ? max(settings.hurry, 1) : 1, move.pace))
            position = move.point
            if move.done {
                position = move.to
                self.move = nil
            } else {
                self.move = move
            }
        }
        covered = isCovered
        // A held Topo has nothing to decide on the clock, and a placed one only his first place:
        // once the transcript has been read and the geometry has held still for a settle, where
        // he is put at once, with no glide, since there is nowhere to glide from.
        if dragging {
            unsettled = false
            return
        }
        if settings.placement != .roam {
            guard unsettled, position == nil, !waiting, field != nil else {
                if position != nil { unsettled = false }
                return
            }
            if now - changed >= settings.settle { perch(.atOnce) }
            return
        }
        guard unsettled, move == nil else { return }
        let quiet = now - changed
        // A frame's quiet is a tick with no geometry since the one before, which the display
        // link's timestamps and the clock's sums put a hair either side of the interval.
        guard quiet >= settings.settle || (covered && quiet >= frame * 0.75) else { return }
        if quiet >= settings.settle { heading = 0 }
        decide(glide: true)
        covered = isCovered
    }

    /// The words moved `drift` points down the screen. Where a glide is going is a gap between
    /// words, so it moves with them and is still a gap on the next frame, and a decision taken
    /// while the transcript scrolls is one decision and not one a frame; a Topo riding the words
    /// moves with them, glide and all, as far as the edge of his room (`MascotField.room`) and no
    /// further. Answers whether the ride reached that edge, which is where it ends.
    private mutating func follow(_ drift: CGFloat, in field: MascotField) -> Bool {
        if riding, let at = position {
            let room = field.room(settings.reach)
            let lowest = max(room.maxY - settings.size.height, room.minY)
            let y = min(max(at.y + drift, room.minY), lowest)
            let applied = y - at.y
            position = CGPoint(x: at.x, y: y)
            if var move {
                move.from.y += applied
                move.to.y += applied
                self.move = move
            }
            if let frame = roost.frame { roost = .gap(frame.offsetBy(dx: 0, dy: applied)) }
            return abs(applied - drift) > MascotRoost.epsilon
        } else if var move {
            move.to.y += drift
            self.move = move
            if let frame = roost.frame { roost = .gap(frame.offsetBy(dx: 0, dy: drift)) }
        }
        return false
    }

    private mutating func decide(glide: Bool) {
        unsettled = false
        riding = false
        guard let field else { return }
        // Displaced by a word, he aims for its far side from where it is going — below a word
        // moving up the screen, above one moving down — so it passes over him once rather than
        // pushing him ahead of it; below a word that is not moving. The nearest gap to that aim
        // is where he goes, so with no room there he goes to its near side instead.
        let margin = settings.clearance.isFinite ? max(settings.clearance, 0) : 0
        var aim = position
        var displacer: CGRect?
        if let picture, let word = field.displacer(of: picture, clearance: margin) {
            displacer = word
            aim = heading > 0
                ? CGPoint(x: picture.minX, y: word.minY - margin - settings.size.height)
                : CGPoint(x: picture.minX, y: word.maxY + margin)
        }
        let next = waiting
            ? MascotRoost.none
            : MascotRoost.of(field, size: settings.size, clearance: settings.clearance, reach: settings.reach,
                             from: aim)
        guard let to = next.frame?.origin else {
            roost = .none
            position = nil
            move = nil
            return
        }
        guard let from = position else {
            roost = next
            face(field)
            position = to
            return
        }
        // Within his own room of where he stands is where he stands — where that is a roost as it
        // stands; one that is not moves however short the move.
        if hypot(to.x - from.x, to.y - from.y) <= settings.clearance,
           MascotRoost.holds(field, frame: CGRect(origin: from, size: settings.size), clearance: settings.clearance,
                             reach: settings.reach) {
            // Where he stands is his roost, which a glide cut short leaves somewhere else.
            roost = .gap(CGRect(origin: from, size: settings.size))
            face(field)
            return
        }
        roost = next
        // On the side of the word it is moving toward, he goes with the words until they stop.
        if let displacer, heading != 0 {
            riding = heading < 0 ? to.y + settings.size.height <= displacer.minY + MascotRoost.epsilon
                                 : to.y >= displacer.maxY - MascotRoost.epsilon
        }
        face(field)
        let distance = hypot(to.x - from.x, to.y - from.y)
        if !glide || settings.reduceMotion || distance == 0 {
            position = to
            return
        }
        let speed = max(settings.speed, 1)
        move = Move(from: from, to: to, duration: Double(distance / speed))
        moves += 1
    }

    /// Why a placed Topo is being put somewhere: his first place, or a new size or clearance, is a
    /// placement (`atOnce`); a new policy or pin is a glide at the stroll (`switched`); the
    /// keyboard coming or going under a pin is a glide, at the hurry up and the stroll back
    /// (`keyboard`); any other geometry moves him with it at once, or turns a glide under way
    /// toward where he now goes (`geometry`).
    enum Arrival: Equatable, Sendable { case atOnce, switched, keyboard, geometry }

    /// Where the look places him, when it does: the glass or the pin, from the geometry as it is,
    /// arriving as `arrival` says. On the glass he rides the pane, placed at once wherever it goes
    /// but for a new policy, which is the one glide. At a pin, the keyboard coming up over him
    /// sends him clear of it at the hurry, and its going sends him back to the pin at the stroll;
    /// the pin itself is the look's and nothing here writes it. A glide under way is turned toward
    /// where he now goes at its own pace, and at the hurry once the keyboard is up. He faces the
    /// half of the transcript his box's centre is in, as he does roaming. With no pane to stand on,
    /// or no transcript to be pinned in, he stands nowhere and is not drawn.
    private mutating func perch(_ arrival: Arrival) {
        unsettled = false
        riding = false
        heading = 0
        covered = false
        guard let field, let target = perchFrame(field) else {
            roost = .none
            position = nil
            move = nil
            return
        }
        roost = settings.placement == .glass ? .glass(target) : .pinned(target)
        face(field)
        let to = target.origin
        guard let from = position, arrival != .atOnce else {
            position = to
            move = nil
            return
        }
        let hurried = settings.placement == .pinned && field.keyboard != nil ? max(settings.hurry, 1) : 1
        if arrival == .switched {
            glide(from: from, to: to, pace: 1)
        } else if let move {
            guard hypot(move.to.x - to.x, move.to.y - to.y) > MascotRoost.epsilon else { return }
            // The same glide, turned: not counted as another.
            glide(from: from, to: to, pace: max(move.pace, hurried))
            moves -= 1
        } else if hypot(to.x - from.x, to.y - from.y) <= MascotRoost.epsilon {
            // Where he is, to a rounding: a pin read back from the place a drag left him. His roost
            // is where he stands, so the two are the same frame.
            roost = settings.placement == .glass ? .glass(CGRect(origin: from, size: settings.size))
                : .pinned(CGRect(origin: from, size: settings.size))
        } else if arrival == .keyboard, settings.placement == .pinned {
            glide(from: from, to: to, pace: hurried)
        } else {
            position = to
        }
    }

    /// Where the look puts his box now, for a placed policy.
    private func perchFrame(_ field: MascotField) -> CGRect? {
        switch settings.placement {
        case .roam:
            return nil
        case .glass:
            return MascotPerch.glass(field, size: settings.size)
        case .pinned:
            return MascotPerch.pinned(settings.pin, in: resting ?? field.pinFrame, keyboard: field.keyboard,
                                      size: settings.size, reach: settings.reach, clearance: settings.clearance)
        }
    }

    /// One glide from `from` to `to` at `pace` times the stroll at the least; under Reduce Motion,
    /// or for no distance at all, a placement.
    private mutating func glide(from: CGPoint, to: CGPoint, pace: CGFloat) {
        let distance = hypot(to.x - from.x, to.y - from.y)
        guard !settings.reduceMotion, distance > MascotRoost.epsilon else {
            position = to
            move = nil
            return
        }
        move = Move(from: from, to: to, duration: Double(distance / max(settings.speed, 1)), pace: pace)
        moves += 1
    }

    // MARK: A drag

    /// Whether a press at `point` is on him: on his box, drawn, and not on the well, which is the
    /// microphone's whatever is drawn over it.
    func grabbable(at point: CGPoint) -> Bool {
        guard let picture, picture.contains(point) else { return false }
        if let well = field?.well, well.contains(point) { return false }
        return true
    }

    /// A finger has him: whatever he was doing stops where he is, and he goes where it takes him.
    /// Nothing happens where he is not drawn.
    @discardableResult
    mutating func grab() -> Bool {
        guard position != nil, !dragging else { return false }
        dragging = true
        drags += 1
        move = nil
        riding = false
        unsettled = false
        covered = false
        return true
    }

    /// The finger has moved his box's origin to `origin`: he is drawn there, at his size, as far as
    /// the transcript's frame with the keyboard down lets his reach go — the place he would be
    /// pinned at if it let go now.
    mutating func drag(to origin: CGPoint) {
        guard dragging, let field, origin.x.isFinite, origin.y.isFinite else { return }
        let frame = MascotPerch.inside(CGRect(origin: origin, size: settings.size), resting ?? field.pinFrame,
                                       reach: settings.reach)
        position = frame.origin
        roost = .pinned(frame)
        face(field)
    }

    /// The finger has let go: he is pinned where he is, as a fraction of the transcript's frame
    /// with the keyboard down, which is answered for the look to keep. From here the roam is the
    /// pinned policy at that pin, so nothing moves him before the look catches up; with the
    /// keyboard up, it lifts him clear of it.
    mutating func drop() -> CGPoint? {
        guard dragging else { return nil }
        dragging = false
        guard let picture, let field else { return nil }
        let pin = MascotPerch.pin(of: picture, in: resting ?? field.pinFrame)
        settings.placement = .pinned
        settings.pin = pin
        // Where he was let go is the pin, to a rounding, unless the keyboard is up over it.
        perch(.keyboard)
        return pin
    }

    /// The facing for the roost just decided: which half of the transcript its centre is in.
    private mutating func face(_ field: MascotField) {
        guard let frame = roost.frame else { return }
        facing = MascotFacing.of(centreX: frame.midX, midlineX: field.visible.midX)
    }
}
#endif

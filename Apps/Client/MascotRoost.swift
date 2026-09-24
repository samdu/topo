import SwiftUI

/// Where the things are that Topo stands clear of, reported by the views that draw them: the
/// transcript's frame, which is where he may stand, every turn, the row being written and the
/// lines under the transcript, which he may not cover, and the composer's pane and well, whose
/// leading flank is where he sits when there is no gap for him.
///
/// Each is an anchor, resolved where he is drawn (`mascotRoams`), so the frames are the ones
/// drawn and not ones worked out: a turn scrolled half out of sight is where it is drawn.
struct MascotScene: PreferenceKey {
    struct Value {
        var visible: Anchor<CGRect>?
        var pane: Anchor<CGRect>?
        var well: Anchor<CGRect>?
        var obstacles: [Anchor<CGRect>] = []
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
    func mascotObstacle() -> some View {
        transformAnchorPreference(key: MascotScene.self, value: .bounds) { $0.obstacles.append($1) }
    }

    /// The frame Topo may stand in: the transcript's.
    func mascotVisible() -> some View {
        transformAnchorPreference(key: MascotScene.self, value: .bounds) { $0.visible = $1 }
    }

    /// The composer's pane, whose leading flank he sits on when no gap holds him.
    func mascotPane() -> some View {
        transformAnchorPreference(key: MascotScene.self, value: .bounds) { $0.pane = $1 }
    }

    /// The composer's well, which he is never drawn over.
    func mascotWell() -> some View {
        transformAnchorPreference(key: MascotScene.self, value: .bounds) { $0.well = $1 }
    }
}

#if os(iOS)
/// The part of the engine's 184×160 picture he is ever drawn in, in art pixels: the union of every
/// pose on every head, yoga's lift and the sign included, with two pixels round it
/// (`MascotGeometryTests.testEveryPoseIsDrawnInsideTheBox` runs every pose and holds that nothing is drawn outside it). The canvas
/// shows this part and no more, so the picture he takes up on the screen is the box a gap has to
/// hold, and not the engine's whole canvas, most of which is nothing.
enum MascotSprite {
    static let box = CGRect(x: 15, y: 47, width: 154, height: 113)

    /// His picture on the screen, in points, at `scale` points an art pixel.
    static func size(scale: CGFloat) -> CGSize {
        CGSize(width: box.width * scale, height: box.height * scale)
    }
}

/// The chat's geometry as Topo reads it, in the space he is drawn in.
struct MascotField: Equatable, Sendable {
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

    /// What he may not be drawn over: what of each obstacle can be seen (`seen`); the pane's
    /// controls — the well and everything from it to the pane's trailing end — whole, since a move
    /// onto the flank may pass them; and the keyboard, whose keys are words too.
    var covering: [CGRect] {
        let seen = seen
        var all = obstacles.map { $0.intersection(seen) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        if let controls { all.append(controls) }
        if let keyboard { all.append(keyboard) }
        return all
    }

    /// The pane's leading flank: from the pane's leading end to the well's leading edge, the
    /// pane's height. Nothing is drawn there but him.
    var flank: CGRect? {
        guard let pane, let well, well.minX > pane.minX else { return nil }
        return CGRect(x: pane.minX, y: pane.minY, width: well.minX - pane.minX, height: pane.height)
    }

    /// The well and the flank beyond it, to the pane's trailing end.
    var controls: CGRect? {
        guard let pane, let well else { return nil }
        return CGRect(x: well.minX, y: pane.minY, width: max(0, pane.maxX - well.minX), height: pane.height)
    }

    /// Whether anything he may not cover overlaps `frame`.
    func covers(_ frame: CGRect) -> Bool {
        covering.contains { MascotRoost.overlap($0, frame) }
    }
}

/// Where Topo stands: a gap in the transcript, the pane's leading flank, or nowhere.
enum MascotRoost: Equatable, Sendable {
    /// A gap in the transcript, and the frame of his picture in it.
    case gap(CGRect)
    /// The pane's leading flank, where no gap held him.
    case flank(CGRect)
    /// Neither holds him, and he is not drawn.
    case none

    var frame: CGRect? {
        switch self {
        case .gap(let frame), .flank(let frame): frame
        case .none: nil
        }
    }

    var name: String {
        switch self {
        case .gap: "gap"
        case .flank: "flank"
        case .none: "none"
        }
    }

    /// Where he stands, from the chat's geometry, the size of his picture, the room he keeps and
    /// where he stands now (`from`, his picture's origin; nil before he has stood anywhere).
    ///
    /// A gap is a place in `field.open` where his picture with `clearance` all round it overlaps
    /// nothing he may not cover. Of the gaps that hold him the nearest to `from` wins — so a new
    /// turn moves him the least — and with no `from` the nearest to the middle of the pane's
    /// leading flank, where he would sit otherwise. With no gap he sits in the middle of that
    /// flank, and a flank that cannot hold his whole picture draws nothing, never a Topo over the
    /// microphone.
    static func of(_ field: MascotField, size: CGSize, clearance: CGFloat, from: CGPoint?) -> MascotRoost {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return .none }
        let margin = clearance.isFinite ? max(clearance, 0) : 0
        let home = field.flank.map { CGPoint(x: $0.midX - size.width / 2, y: $0.midY - size.height / 2) }
            ?? CGPoint(x: field.open.minX, y: field.open.maxY - size.height)
        if let spot = nearestGap(field, size: size, margin: margin, to: from ?? home) {
            return .gap(CGRect(origin: spot, size: size))
        }
        if let flank = field.flank, size.width <= flank.width, size.height <= flank.height {
            return .flank(CGRect(x: flank.midX - size.width / 2, y: flank.midY - size.height / 2,
                                 width: size.width, height: size.height))
        }
        return .none
    }

    /// The origin of his picture in the nearest gap to `target`, or nil for none.
    ///
    /// The gap is found for his picture grown by the margin, whose origin is allowed anywhere in
    /// `open` that leaves it inside and outside every obstacle grown by its size. The nearest
    /// allowed point to the target is the target itself or lies on the edge of one of those
    /// regions, at the target's own x or y or at a corner of two of them, so the lines through
    /// the target and every edge, crossed, hold it.
    private static func nearestGap(_ field: MascotField, size: CGSize, margin: CGFloat, to target: CGPoint) -> CGPoint? {
        let open = field.open
        let grown = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        guard grown.width <= open.width, grown.height <= open.height else { return nil }
        let allowedX = open.minX...(open.maxX - grown.width)
        let allowedY = open.minY...(open.maxY - grown.height)
        let forbidden = field.covering.map {
            CGRect(x: $0.minX - grown.width, y: $0.minY - grown.height,
                   width: $0.width + grown.width, height: $0.height + grown.height)
        }
        let aim = CGPoint(x: target.x - margin, y: target.y - margin)
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
                               || (abs(distance - best.distance) <= epsilon && (y, x) < (best.point.y, best.point.x))) {
                    continue
                }
                best = (point, distance)
            }
        }
        return best.map { CGPoint(x: $0.point.x + margin, y: $0.point.y + margin) }
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
/// is never made mid-move, and a roost within `clearance` of where he stands is not a move. A move
/// is one eased glide at `speed` points a second on average — `hurry` times that on every frame
/// anything is over him, and back to the stroll the frame he is clear — which under Reduce Motion
/// is a placement with no glide. He is drawn above everything but the keyboard wherever he is, so
/// nothing is judged about whether he may be seen: he is drawn whenever he stands anywhere.
struct MascotRoam: Equatable, Sendable {
    struct Settings: Equatable, Sendable {
        var size: CGSize
        var clearance: CGFloat
        var speed: CGFloat
        var hurry: CGFloat
        var settle: Double
        var reduceMotion = false

        init(size: CGSize, clearance: CGFloat, speed: CGFloat, hurry: CGFloat = 10, settle: Double,
             reduceMotion: Bool = false) {
            self.size = size
            self.clearance = clearance
            self.speed = speed
            self.hurry = hurry
            self.settle = settle
            self.reduceMotion = reduceMotion
        }

        init(_ mascot: Look.Mascot, reduceMotion: Bool) {
            self.init(size: MascotSprite.size(scale: mascot.scale), clearance: mascot.clearance,
                      speed: mascot.roamSpeed, hurry: mascot.hurry, settle: mascot.roamSettle,
                      reduceMotion: reduceMotion)
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
    /// His picture's origin now; nil while he stands nowhere.
    private(set) var position: CGPoint?
    private(set) var move: Move?
    /// Something he may not cover overlaps him where he is now.
    private(set) var covered = false
    /// How many glides have begun, for the tests.
    private(set) var moves = 0
    /// The geometry changed since the roost was last decided.
    private(set) var unsettled = false
    /// When the geometry last changed, and when the roam was last moved on.
    private var changed = -Double.infinity
    private var now = 0.0
    /// When the clock last moved the glide on, which a geometry arriving between frames does not.
    private var advanced = 0.0
    /// The time a frame lasts, which is the quiet a covered Topo waits for.
    var frame: Double

    init(_ settings: Settings, frame: Double = 1.0 / 30) {
        self.settings = settings
        self.frame = frame
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
    mutating func observe(_ field: MascotField, at time: Double) {
        now = max(now, time)
        guard field != self.field else { return }
        self.field = field
        changed = now
        unsettled = true
        covered = picture.map(field.covers) ?? false
    }

    /// The settings, which a look or Reduce Motion can change: a new size is a new geometry to
    /// him, so it is decided again.
    mutating func use(_ settings: Settings) {
        guard settings != self.settings else { return }
        let resized = settings.size != self.settings.size
        self.settings = settings
        if resized {
            changed = now
            unsettled = true
            if move == nil, position != nil { decide(glide: false) }
        }
        covered = picture.flatMap { picture in field.map { $0.covers(picture) } } ?? false
    }

    /// The clock at `time`: the glide moved on, whether he is covered judged where he now is, and
    /// the roost decided if the geometry has been quiet long enough.
    mutating func advance(to time: Double) {
        let dt = max(time - advanced, 0)
        advanced = max(advanced, time)
        now = max(now, time)
        if var move {
            // The pace this frame is judged where he was over it: in a hurry while covered.
            move.elapsed += dt * Double(covered ? max(settings.hurry, 1) : 1)
            position = move.point
            if move.done {
                position = move.to
                self.move = nil
            } else {
                self.move = move
            }
        }
        covered = picture.flatMap { picture in field.map { $0.covers(picture) } } ?? false
        guard unsettled, move == nil else { return }
        let quiet = now - changed
        guard quiet >= settings.settle || (covered && quiet >= frame) else { return }
        decide(glide: true)
        covered = picture.flatMap { picture in field.map { $0.covers(picture) } } ?? false
    }

    private mutating func decide(glide: Bool) {
        unsettled = false
        guard let field else { return }
        let next = MascotRoost.of(field, size: settings.size, clearance: settings.clearance, from: position)
        guard let to = next.frame?.origin else {
            roost = .none
            position = nil
            move = nil
            return
        }
        guard let from = position else {
            roost = next
            position = to
            return
        }
        // Within his own room of where he stands is where he stands.
        if hypot(to.x - from.x, to.y - from.y) <= settings.clearance, !field.covers(CGRect(origin: from, size: settings.size)) {
            return
        }
        roost = next
        let distance = hypot(to.x - from.x, to.y - from.y)
        if !glide || settings.reduceMotion || distance == 0 {
            position = to
            return
        }
        let speed = max(settings.speed, 1)
        move = Move(from: from, to: to, duration: Double(distance / speed))
        moves += 1
    }
}
#endif

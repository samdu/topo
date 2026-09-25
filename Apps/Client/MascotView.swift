#if os(iOS)
import QuartzCore
import SwiftUI
import TopoMascot
import UIKit

/// The engine run a frame at a time, and only while he can be seen. It holds the engine, the one
/// buffer it draws into and the picture made from it; what calls `tick` is the canvas's display
/// link, which runs exactly while `conditions.animates` does.
///
/// Drawn on the main thread: the port measured 3.2–4.5 ms a frame there, live at 60 Hz on an
/// iPhone 15 Pro (experiments `topo-mascot-swift`), and this draws half as often. A debug build
/// prints what the frames here cost, every `reportEvery` of them, as `[topo-debug] mascot: …`.
@MainActor
final class MascotDriver {
    /// What decides whether he is drawn.
    struct Conditions: Equatable, Sendable {
        /// The scene is in front: not backgrounded, not behind the lock, not inactive.
        var active = false
        /// The canvas is in a window.
        var onScreen = false
        /// How opaque he is drawn: the microphone's hold fades him with the glass's flanks, to
        /// `composer.flank.heldOpacity`. Any opacity above zero is him seen, so frames go on;
        /// at zero there is nothing to draw, and they stop.
        var opacity = 1.0
        /// A sheet is over the chat.
        var covered = false
        /// Reduce Motion: he is held still in his idle pose.
        var reduceMotion = false
        /// He stands nowhere (`MascotRoam.hidden`): nothing of him is drawn.
        var hidden = false

        /// The chat is in front of the person with him on it, whether or not he stands anywhere:
        /// what his going from roost to roost needs, since a roost is decided from nowhere too.
        var present: Bool { active && onScreen && opacity > 0 && !covered }
        var visible: Bool { present && !hidden }
        /// Frames run: he is seen and may move.
        var animates: Bool { visible && !reduceMotion }
        /// One still frame, drawn once per state: he is seen and may not move.
        var still: Bool { visible && reduceMotion }
    }

    var conditions = Conditions() { didSet { if conditions != oldValue { holdStill() } } }
    /// What the engine is handed.
    var input = TopoInput() { didSet { holdStill() } }
    /// Told every picture drawn, and how far along the shelf he is.
    var onFrame: ((CGImage, Double) -> Void)?

    /// Every frame the engine has drawn, moving or still.
    private(set) var frames = 0
    private(set) var image: CGImage?

    private let engine = Topo()
    private var rgba = [UInt8](repeating: 0, count: Topo.width * Topo.height * 4)
    private let space = CGColorSpaceCreateDeviceRGB()
    /// What the still frame on the canvas was drawn for, so Reduce Motion draws once per picture
    /// rather than once per input.
    private var stillFor: Still?

    /// What of the input the still is drawn differently for, as the engine reads it: the head the
    /// model picks (`levelForModel`, by family, so two ids of one model are one head), the band
    /// the tokens fall in (`loadForTokens`) and the facing, which mirrors the whole picture (any
    /// word but `right` is `left`, as the engine reads it). Tokens moving within a band, a pose, a
    /// sign or the stroll's corner change nothing of the idle still, and `MascotState` sets
    /// nothing else it is drawn with: style, shading and relief are left at the engine's own.
    struct Still: Equatable {
        var level: Double
        var load: Load
        var facing: String

        init(_ input: TopoInput) {
            let rest = Self.rest
            level = input.model.flatMap { $0.isEmpty ? nil : levelForModel($0) } ?? input.level ?? rest.level
            load = input.tokens.map(loadForTokens) ?? input.load.flatMap(Load.init(rawValue:)) ?? rest.load
            facing = input.facing.map { $0 == "right" ? "right" : "left" } ?? rest.facing
        }

        /// A fresh engine's, which is what the still starts from and keeps where the input is silent.
        private static let rest = Topo().state
    }

    /// One frame, `dt` seconds after the last: the engine moved on and drawn, if he animates.
    func tick(_ dt: Double) {
        guard conditions.animates else { return }
        stillFor = nil
        let start = CACurrentMediaTime()
        engine.update(dt, input)
        engine.draw(&rgba)
        publish(x: engine.x)
        #if DEBUG
        // The whole frame: the engine, the picture made from its buffer and its hand-off to the
        // layer, since all three are the main thread's.
        measure(CACurrentMediaTime() - start)
        #endif
    }

    /// Under Reduce Motion he is the idle pose, settled, at home: a fresh engine walked to where
    /// the pose has landed and drawn once, with the model, the load and the facing of the state.
    ///
    /// 2.9 s at a thirtieth is past the pose's settle (the sheet settles in 2.2) and before the
    /// engine's first glance (3 s) and its second blink (at least 2.5 s after the first at 2 s):
    /// a still of the engine's own face at rest, with no eye half shut.
    private func holdStill() {
        let key = Still(input)
        guard conditions.still, stillFor != key else { return }
        stillFor = key
        let still = Topo(random: { 0.5 })
        var idle = input
        idle.activity = "idle"
        idle.sign = nil
        for _ in 0..<Self.stillSteps { still.update(1.0 / 30, idle) }
        still.draw(&rgba)
        publish(x: 0)
    }

    static let stillSteps = 87

    private func publish(x: Double) {
        frames += 1
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: Topo.width, height: Topo.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: Topo.width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        self.image = image
        onFrame?(image, x)
    }

    #if DEBUG
    static let reportEvery = 300
    private var spent: [Double] = []

    /// What the frames cost where they run: the mean, the 95th percentile and the worst of the
    /// last `reportEvery`, in milliseconds, the whole frame: update, draw, picture and layer.
    private func measure(_ seconds: Double) {
        spent.append(seconds * 1000)
        guard spent.count >= Self.reportEvery else { return }
        DebugRun.say(Self.frameLine(spent, activity: input.activity ?? "idle", facing: engine.facing))
        spent.removeAll(keepingCapacity: true)
    }

    /// The line a debug build prints for `spent`, a run of frame times in milliseconds: how many,
    /// the pose, the facing in force (which lags the facing asked for until he is home), and the
    /// mean, the 95th percentile and the worst.
    static func frameLine(_ spent: [Double], activity: String, facing: String) -> String {
        let sorted = spent.sorted(), n = sorted.count
        guard n > 0 else { return "mascot: 0 frames, \(activity), facing \(facing)" }
        return String(format: "mascot: %d frames, %@, facing %@, mean %.2f ms, p95 %.2f ms, max %.2f ms",
                      n, activity, facing, sorted.reduce(0, +) / Double(n), sorted[n * 95 / 100], sorted[n - 1])
    }

    /// The facing in force, as the engine draws it now.
    var facingInForce: String { engine.facing }
    #endif
}

/// The view he is drawn in, laid over the whole of the chat: one layer holding the engine's
/// whole picture, magnified nearest-neighbour and put so that the part he takes up at rest
/// (`MascotSprite.box`) is where his roam says he is; what a pose draws past that box is drawn
/// over whatever is there, except on the glass, where he is drawn inside the empty flank. The view
/// itself takes no touch and is nothing to accessibility, so everything under it is found and
/// pressed exactly as it would be without him.
///
/// What he takes is a long press on his box, less the well's frame, and the drag that follows it
/// (`grab`, a `UILongPressGestureRecognizer` on the window, since the canvas is laid over the chat
/// and not in it): the finger moves him, and letting go pins him there (`onPin`). A long press, so
/// a scroll that starts on him moves off before it fires and scrolls; a tap on him fires nothing
/// and is whatever is under him's. The well is never his: a touch on it is not handed to the
/// recognizer at all, so the microphone's own gesture has it whatever is drawn over it.
@MainActor
final class MascotCanvas: UIView, UIGestureRecognizerDelegate {
    let driver = MascotDriver()
    /// What the picture is drawn inside: the whole canvas, or on the glass the empty flank.
    private let stage = CALayer()
    private let sprite = CALayer()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var interval = 1.0 / 30
    /// What he stands for, before the walk is put on him for a glide.
    private var input = TopoInput()
    /// What decides whether he is drawn, as SwiftUI tells it: the roam says whether he stands anywhere.
    private var told = MascotDriver.Conditions()
    private(set) var roam: MascotRoam?
    /// How long the canvas has been ticking: the roam's clock, which stops with the link, so a
    /// glide the chat going behind a sheet interrupts carries on from where it was.
    private(set) var clock = 0.0
    /// Told each time what he stands in, whether he stands anywhere or how many glides he has begun
    /// changes. A debug build hands it to the chat's report.
    var onReport: ((MascotRoam.Report) -> Void)?
    private var reported: MascotRoam.Report?
    /// Told the facing each roost decides (`MascotRoam.facing`) when it is not the one last told,
    /// which is how it reaches `Mascot.facing` and so the engine: at the decision, not per frame.
    var onFace: ((MascotFacing) -> Void)?
    private var faced: MascotFacing?
    /// Told the pin a drag let go of him at, as fractions of the transcript's frame carried to
    /// the pane's foot with the keyboard down, for this device's override to keep (`Tuning.pin(at:)`).
    var onPin: ((CGPoint) -> Void)?
    /// The press that picks him up. It lives on the window, where it sees the touches that start
    /// on his box, which land on whatever is under him.
    private(set) lazy var grab: UILongPressGestureRecognizer = {
        let grab = UILongPressGestureRecognizer(target: self, action: #selector(grabbed(_:)))
        grab.minimumPressDuration = Self.holdToGrab
        grab.allowableMovement = Self.grabSlop
        grab.cancelsTouchesInView = true
        grab.delegate = self
        return grab
    }()
    /// Where the finger took his box from, as the offset of the box's origin from it.
    private var held: CGSize = .zero
    /// The view SwiftUI places on the pane for him to stand in while he is on the glass
    /// (`MascotGlassStage`), found through the port they share.
    var glass: MascotGlassPort? {
        didSet { if glass !== oldValue { glass?.canvas = self } }
    }

    /// How long a press on him has to be still before it picks him up: long enough that a tap and
    /// the start of a scroll are over first.
    static let holdToGrab: TimeInterval = 0.5
    /// How far a finger may move before it is a scroll and not a press.
    static let grabSlop: CGFloat = 10

    /// Whether the display link is running, which is whether frames are being asked for.
    var isTicking: Bool { link != nil }
    /// The rate the link is asked for, frames a second, while it runs.
    var frameRate: Float? { link?.preferredFrameRateRange.preferred }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        sprite.magnificationFilter = .nearest
        sprite.minificationFilter = .nearest
        // The layer is moved every frame; an implicit animation would smear what is pixels.
        sprite.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "frame": NSNull(),
                          "opacity": NSNull()]
        sprite.opacity = 0
        stage.masksToBounds = true
        stage.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        stage.addSublayer(sprite)
        layer.addSublayer(stage)
        driver.onFrame = { [weak self] image, _ in self?.show(image) }
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    /// Everything the view is told by SwiftUI, applied at once: the geometry is the roam's newest,
    /// and whether he is covered is judged against it before anything is drawn.
    /// `ready` is whether the transcript has been read once: until then he is not drawn.
    func apply(input: TopoInput, field: MascotField?, settings: MascotRoam.Settings, interval: Double,
               ready: Bool = true, conditions: MascotDriver.Conditions) {
        self.input = input
        self.interval = interval
        told = conditions
        var roam = roam ?? MascotRoam(settings, frame: interval)
        roam.use(settings)
        roam.frame = interval
        roam.wait(!ready, at: clock)
        if let field {
            #if DEBUG
            if field != roam.field { MascotTrace.shared?.observed(field, at: clock) }
            #endif
            roam.observe(field, at: clock)
        }
        self.roam = roam
        sync()
    }

    /// His box where the roam has it now, in the canvas: what the roost holds.
    var spriteFrame: CGRect { roam?.picture ?? .zero }
    /// The whole of the engine's picture as the layer draws it, round that box, in the canvas.
    var drawnFrame: CGRect {
        guard let parent = sprite.superlayer else { return sprite.frame }
        return parent.convert(sprite.frame, to: layer)
    }
    /// Whether he is drawn in the glass's stage rather than over the chat.
    var onGlassStage: Bool { sprite.superlayer != nil && sprite.superlayer === glass?.view?.layer }
    /// Whether he is being drawn at all.
    var showing: Bool { sprite.opacity > 0 }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        grab.view?.removeGestureRecognizer(grab)
        newWindow?.addGestureRecognizer(grab)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sync()
    }

    /// Drawn again as things stand: the glass's stage has come or gone.
    func resync() { sync() }

    // MARK: Picking him up

    /// A touch is handed to the press only where he can be picked up: drawn, in front, with no
    /// sheet over the chat, on his box and off the well.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        grabbable(at: touch.location(in: self))
    }

    /// Whether a press at `point`, in the canvas, would pick him up.
    func grabbable(at point: CGPoint) -> Bool {
        guard driver.conditions.visible, let roam else { return false }
        return roam.grabbable(at: point)
    }

    /// His press waits on nothing, and every other recognizer waits for it to fail before it acts
    /// on a touch it was handed — a turn's own hold, a button — except any pan
    /// (`UIPanGestureRecognizer`, a scroll's among them), which begins on its own movement, and a
    /// finger that moves past the slop ends his press.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        !(other is UIPanGestureRecognizer)
    }

    @objc private func grabbed(_ press: UILongPressGestureRecognizer) {
        let point = press.location(in: self)
        switch press.state {
        case .began:
            pickUp(at: point)
        case .changed:
            move(to: point)
        case .ended:
            guard roam?.dragging == true else { return }
            move(to: point)
            var roam = roam
            let pin = roam?.drop()
            self.roam = roam
            sync()
            if let pin { onPin?(pin) }
        case .cancelled, .failed:
            cancel()
        default:
            break
        }
    }

    /// Picked up by a finger at `point`, which keeps the place on him it took him by.
    @discardableResult
    private func pickUp(at point: CGPoint) -> Bool {
        guard var roam, let picture = roam.picture else { return false }
        guard roam.grab() else { return false }
        held = CGSize(width: picture.minX - point.x, height: picture.minY - point.y)
        self.roam = roam
        sync()
        return true
    }

    /// The finger at `point`: his box where it has him.
    func move(to point: CGPoint) {
        guard var roam, roam.dragging else { return }
        roam.drag(to: CGPoint(x: point.x + held.width, y: point.y + held.height))
        self.roam = roam
        sync()
    }

    /// A drag scripted as a test would make one: picked up at `from`, carried to `to`, let go.
    /// Answers the pin, or nil where `from` does not pick him up.
    func drag(from: CGPoint, to: CGPoint) -> CGPoint? {
        guard grabbable(at: from), pickUp(at: from) else { return nil }
        move(to: to)
        guard var dropped = self.roam else { return nil }
        let pin = dropped.drop()
        self.roam = dropped
        sync()
        if let pin { onPin?(pin) }
        return pin
    }

    /// A press scripted as a test would make one, picked up at `from`, carried to `to` and then
    /// cancelled rather than let go. Answers whether it picked him up.
    @discardableResult
    func cancelledDrag(from: CGPoint, to: CGPoint) -> Bool {
        guard grabbable(at: from), pickUp(at: from) else { return false }
        move(to: to)
        cancel()
        return true
    }

    /// The press taken away rather than let go: nothing is pinned, and he goes back.
    private func cancel() {
        guard var roam, roam.dragging else { return }
        roam.cancelDrag()
        self.roam = roam
        sync()
    }

    /// The roam's answer handed to what draws him: the walk while he glides and his own activity
    /// otherwise, the driver told whether he stands anywhere, the layer put where he is and shown
    /// or not with it, and the link run exactly while something needs it. Nothing over him hides
    /// him: he is drawn above everything in the chat, and only the keyboard is above him.
    private func sync() {
        guard let roam else { return }
        var conditions = told
        conditions.onScreen = window != nil
        conditions.hidden = roam.hidden
        var worn = input
        // The engine walks along its own shelf; where he is on the screen is the roam's, so the
        // stroll goes nowhere and a glide is the walk worn in place.
        worn.corner = 0
        if roam.walking {
            worn.activity = "walk"
            worn.sign = nil
        }
        if driver.input.activity != worn.activity || driver.input.model != worn.model
            || driver.input.tokens != worn.tokens || driver.input.sign != worn.sign || driver.input.corner != 0
            || driver.input.facing != worn.facing {
            driver.input = worn
        }
        driver.conditions = conditions
        reschedule()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // On the glass he is drawn in the stage SwiftUI places from the pane, at the same place in
        // it whatever the pane's height, so he is drawn wherever the pane is drawn, on the
        // keyboard's curve, in the keyboard's own transaction; nothing here animates him.
        if let (view, rect) = glassStage(roam) {
            if sprite.superlayer !== view.layer { view.layer.addSublayer(sprite) }
            stage.frame = bounds
            if let picture = roam.picture {
                sprite.frame = MascotSprite.drawn(around: picture).offsetBy(dx: -rect.minX, dy: -rect.minY)
            }
        } else {
            if sprite.superlayer !== stage { stage.addSublayer(sprite) }
            stage.frame = clip(roam) ?? bounds
            if let picture = roam.picture {
                sprite.frame = MascotSprite.drawn(around: picture).offsetBy(dx: -stage.frame.minX, dy: -stage.frame.minY)
            }
        }
        sprite.opacity = roam.hidden ? 0 : 1
        CATransaction.commit()
        if !roam.hidden, roam.facing != faced {
            faced = roam.facing
            onFace?(roam.facing)
        }
        report(roam)
    }

    /// The glass's stage and where it is in the canvas, while he stands on the glass, not gliding
    /// and not in a finger, and SwiftUI has put the stage in the window.
    private func glassStage(_ roam: MascotRoam) -> (UIView, CGRect)? {
        guard case .glass = roam.roost, !roam.walking, !roam.dragging, let field = roam.field,
              let view = glass?.view, view.window != nil, view.window === window,
              let rect = MascotPerch.glassStage(field, size: roam.settings.size) else { return nil }
        return (view, rect)
    }

    /// What he is drawn inside with no glass stage to stand in: on the glass, standing there and
    /// not in a finger, the empty flank, so no pose is drawn over the microphone; the whole canvas
    /// otherwise.
    private func clip(_ roam: MascotRoam) -> CGRect? {
        guard case .glass = roam.roost, !roam.walking, !roam.dragging, let field = roam.field,
              let slot = MascotPerch.glassSlot(field)?.intersection(bounds), !slot.isNull else { return nil }
        return slot
    }

    /// Where the picture is drawn, in the canvas, as the layers have it: the whole picture, less
    /// what every clipping layer it is inside cuts off — on the glass, the flank.
    var shownFrame: CGRect {
        var shown = drawnFrame
        var parent = sprite.superlayer
        while let clip = parent, clip !== window?.layer {
            if clip.masksToBounds { shown = shown.intersection(clip.convert(clip.bounds, to: layer)) }
            parent = clip.superlayer
        }
        return shown
    }

    private func report(_ roam: MascotRoam) {
        guard let onReport else { return }
        var now = roam.report
        #if DEBUG
        now.trail = trail
        #endif
        guard now != reported else { return }
        reported = now
        sequence += 1
        recent.append(.init(sequence: sequence, frame: now.frame, pane: now.pane, hidden: now.hidden))
        if recent.count > Self.recentReports { recent.removeFirst(recent.count - Self.recentReports) }
        now.sequence = sequence
        now.recent = recent
        onReport(now)
    }

    /// How many reports the debug report carries back: about seven seconds of a glide at 30
    /// frames a second.
    private static let recentReports = 200
    private var sequence = 0
    private var recent: [MascotRoam.Report.Glimpse] = []

    private func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = image
        CATransaction.commit()
    }

    /// The link runs while he animates, or while his roam has a glide or a decision waiting on the
    /// clock, and not a frame longer: a Topo standing nowhere with nothing to decide asks for nothing.
    private func reschedule() {
        let wanted = driver.conditions.animates || (driver.conditions.present && (roam?.needsTime ?? false))
        if wanted {
            let fps = Float(1 / interval)
            if let link {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
                return
            }
            let link = CADisplayLink(target: Tick(self), selector: #selector(Tick.fire(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
            link.add(to: .main, forMode: .common)
            self.link = link
            last = 0
        } else {
            link?.invalidate()
            link = nil
        }
    }

    fileprivate func fire(_ link: CADisplayLink) { fire(at: link.targetTimestamp) }

    /// A display-link callback for the frame shown at `timestamp`: the clock moves on by the real
    /// time since the last one, so the settle, the glide and the engine run at their own pace at
    /// any frame interval. The step is capped at `Self.stepCap(interval:)`, two frames at a slow
    /// rate, room for a timestamp's jitter, so a stall — the main thread held, the app suspended with the link standing — moves
    /// him on by at most that much rather than by the whole of it; and the first callback after
    /// the link is made, which has no last timestamp, moves him one frame.
    func fire(at timestamp: CFTimeInterval) {
        let dt = last == 0 ? interval : min(max(timestamp - last, 0), Self.stepCap(interval: interval))
        last = timestamp
        step(dt)
    }

    /// The most one callback moves the clock: two frame intervals, or a tenth of a second where
    /// that is shorter, so a frame or two dropped at 30 a second is still real time.
    static func stepCap(interval: Double) -> Double { max(interval * 2, 0.1) }

    /// One frame, `dt` seconds on: the roam's clock and the engine moved on together.
    func step(_ dt: Double) {
        clock += dt
        #if DEBUG
        sample()
        #endif
        roam?.advance(to: clock)
        #if DEBUG
        if let roam { MascotTrace.shared?.advanced(roam, at: clock) }
        #endif
        sync()
        driver.tick(dt)
    }

    #if DEBUG
    /// While he is on the glass, what the screen shows each frame something is moving: the top of
    /// his whole picture and the keyboard's top edge (the screen's foot where there is none), both
    /// as drawn — the presentation layers, in the screen — each run of moving frames with the still
    /// frame before it and the one after, so a suite can hold that he moves with the pane as the
    /// keyboard carries it, frame by frame, from where he stood to where he stands.
    private(set) var trail: [MascotRoam.Report.Drawn] = []
    private var trailMoving = false
    private var still: MascotRoam.Report.Drawn?

    private func sample() {
        guard let roam, case .glass = roam.roost, let window else { return }
        let drawn = sprite.presentation() ?? sprite
        let model = sprite.convert(sprite.bounds, to: nil)
        let shown = drawn.convert(drawn.bounds, to: nil)
        let keyboard = KeyboardProbe.edge()
        let foot = window.frame.maxY
        let moving = abs(shown.minY - model.minY) > 0.5 || (keyboard.map { abs($0.drawn - $0.model) > 0.5 } ?? false)
        let now = MascotRoam.Report.Drawn(t: clock, top: Double(shown.minY + window.frame.minY),
                                          keyboard: Double(min(keyboard?.drawn ?? foot, foot)), moving: moving)
        defer { if trail.count > 120 { trail.removeFirst(trail.count - 120) } }
        if moving {
            if !trailMoving, let still { trail.append(still) }
            trail.append(now)
        } else if trailMoving {
            trail.append(now)
        }
        trailMoving = moving
        if !moving { still = now }
    }
    #endif

    /// The link holds its target, so the target is this rather than the canvas: a canvas taken
    /// out of the hierarchy is not kept alive by its own clock.
    /// The link is added to the main run loop, so it fires on the main thread.
    @MainActor
    private final class Tick: NSObject {
        weak var canvas: MascotCanvas?
        init(_ canvas: MascotCanvas) { self.canvas = canvas }
        @objc func fire(_ link: CADisplayLink) {
            guard let canvas else { return link.invalidate() }
            canvas.fire(link)
        }
    }
}

extension MascotRoam {
    /// What a debug build reports of him: the roost he stands in or is going to, the frame of his
    /// picture where he is now (`frame`) and at that roost (`to`), which differ only mid-glide,
    /// whether he stands nowhere, is gliding or has anything over him, how many glides he has
    /// begun, and the composer's pane as he read it (`pane`), in the same space, so a suite can
    /// hold where he stands against the glass.
    struct Report: Codable, Equatable, Sendable {
        var roost: String
        var frame: [Double]?
        var to: [Double]?
        var hidden: Bool
        var walking: Bool
        var covered: Bool
        var moves: Int
        var pane: [Double]?
        /// The policy he is placed by (`Look.Mascot.Placement`), whether a finger has him, how
        /// many drags have begun, and the pin he is placed at, as the roam holds them.
        var placement = "roam"
        var dragging = false
        var drags = 0
        var pin: [Double]?
        /// The well and the transcript's frame as he read them, in the same space.
        var well: [Double]?
        var visible: [Double]?
        /// Counts the reports the canvas has made, one more each time, so a reader polling the
        /// latest can tell it missed none.
        var sequence = 0
        /// The last reports, oldest first, each as its sequence, his frame, the pane and whether
        /// he stood nowhere: a reader polling the latest report sees every frame in between.
        var recent: [Glimpse] = []

        /// The glass's frames as drawn while something moved (`MascotCanvas.trail`), debug only.
        var trail: [Drawn] = []

        struct Drawn: Codable, Equatable, Sendable {
            var t: Double
            var top: Double
            var keyboard: Double
            var moving: Bool
        }

        struct Glimpse: Codable, Equatable, Sendable {
            var sequence: Int
            var frame: [Double]?
            var pane: [Double]?
            var hidden: Bool
        }
    }

    var report: Report {
        func numbers(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) } }
        return Report(roost: roost.name, frame: picture.map(numbers), to: roost.frame.map(numbers),
                      hidden: hidden, walking: walking, covered: covered, moves: moves,
                      pane: field?.pane.map(numbers), placement: settings.placement.rawValue, dragging: dragging,
                      drags: drags, pin: [Double(settings.pin.x), Double(settings.pin.y)],
                      well: field?.well.map(numbers), visible: field.map { numbers($0.visible) })
    }
}

#if DEBUG
/// `TOPO_DEBUG_MASCOT_TRACE=<file name>`: every geometry the canvas hands his roam and every tick
/// of its clock, with where that left him, written a JSON object a line to that name in the app's
/// temporary directory. A geometry is written as the roam is handed it (`observe`), and a tick as
/// the clock moved it on (`advance`), in the order they happened, so a run on the simulator can be
/// replayed through `MascotRoam` in a test exactly as it ran. Nothing is written when the
/// variable is absent, which is every ordinary run.
@MainActor
final class MascotTrace {
    static let variable = "TOPO_DEBUG_MASCOT_TRACE"
    static let shared: MascotTrace? = ProcessInfo.processInfo.environment[variable].flatMap { MascotTrace(name: $0) }

    private let handle: FileHandle
    private let encoder = JSONEncoder()

    init?(name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        encoder.outputFormatting = .sortedKeys
        DebugRun.say("mascot trace: \(url.path)")
    }

    struct Line: Codable {
        var t: Double
        var field: MascotField?
        var frame: CGRect?
        var to: CGRect?
        var covered: Bool?
        var walking: Bool?
        var moves: Int?
    }

    func observed(_ field: MascotField, at time: Double) { write(Line(t: time, field: field)) }

    func advanced(_ roam: MascotRoam, at time: Double) {
        write(Line(t: time, frame: roam.picture, to: roam.roost.frame, covered: roam.covered, walking: roam.walking,
                   moves: roam.moves))
    }

    private func write(_ line: Line) {
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        handle.write(data)
    }
}
#endif

#if DEBUG
/// The keyboard's top edge in the screen, as drawn and as laid out, for the glass's trail: the
/// container UIKit slides the keyboard in with, in its text-effects window, read off its
/// presentation layer.
@MainActor
enum KeyboardProbe {
    static func edge() -> (drawn: CGFloat, model: CGFloat)? {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                guard let host = find(in: window) else { continue }
                let drawn = host.layer.presentation() ?? host.layer
                let shown = drawn.convert(drawn.bounds, to: nil).offsetBy(dx: 0, dy: window.frame.minY)
                let laid = host.convert(host.bounds, to: nil).offsetBy(dx: 0, dy: window.frame.minY)
                return (shown.minY, laid.minY)
            }
        }
        return nil
    }

    private static func find(in view: UIView) -> UIView? {
        if NSStringFromClass(type(of: view)) == "UIKeyboardItemContainerView" { return view }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }
}
#endif

/// Where the canvas finds the stage SwiftUI places on the glass for him: the one object both
/// views are handed.
@MainActor
final class MascotGlassPort {
    weak var view: UIView? {
        didSet { if view !== oldValue { canvas?.resync() } }
    }
    weak var canvas: MascotCanvas?
}

/// The stage he stands in on the glass: a view SwiftUI frames at `MascotPerch.glassStage` from the
/// pane's own anchor, inside a clip of the flank, so both are animated in the same transaction as
/// the pane — the keyboard's — and he, filling it, with them.
struct MascotGlassStage: UIViewRepresentable {
    let port: MascotGlassPort

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        port.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if port.view !== view { port.view = view }
    }
}

/// The canvas in SwiftUI.
struct MascotOverChat: UIViewRepresentable {
    var input: TopoInput
    var field: MascotField?
    var settings: MascotRoam.Settings
    var interval: Double
    var ready = true
    var conditions: MascotDriver.Conditions
    var report: ((MascotRoam.Report) -> Void)?
    var face: ((MascotFacing) -> Void)?
    var pin: ((CGPoint) -> Void)?
    var glass: MascotGlassPort?

    func makeUIView(context: Context) -> MascotCanvas { MascotCanvas(frame: .zero) }

    func updateUIView(_ canvas: MascotCanvas, context: Context) {
        canvas.glass = glass
        canvas.onReport = report
        canvas.onFace = face
        canvas.onPin = pin
        canvas.apply(input: input, field: field, settings: settings, interval: interval, ready: ready,
                     conditions: conditions)
    }

    static func dismantleUIView(_ canvas: MascotCanvas, coordinator: ()) {
        canvas.driver.conditions.onScreen = false
    }
}

extension MascotScene.Value {
    /// The anchors resolved where he is drawn, or nil before the transcript has reported its frame.
    /// `keyboardTop` is the keyboard's top edge in the global space, while it is up.
    func field(in proxy: GeometryProxy, keyboardTop: CGFloat?) -> MascotField? {
        guard let visible else { return nil }
        var keyboard: CGRect?
        if let keyboardTop {
            let top = keyboardTop - proxy.frame(in: .global).minY
            keyboard = CGRect(x: 0, y: top, width: proxy.size.width, height: max(proxy.size.height - top, 0) + 10_000)
        }
        return MascotField(visible: proxy[visible], obstacles: obstacles.flatMap { proxy[$0] },
                           pane: pane.map { proxy[$0] }, well: well.map { proxy[$0] }, keyboard: keyboard)
    }
}

/// Topo over the chat, drawn from the state he is handed, standing where the chat's geometry
/// leaves him room.
struct MascotLayer: View {
    let state: MascotState
    let scene: MascotScene.Value
    /// How opaque he is drawn: the microphone's hold fades him with the glass's flanks.
    var opacity = 1.0
    /// A sheet is over the chat.
    var covered = false
    var keyboardTop: CGFloat?
    /// The transcript has been read once. Until it has, the page is about to fill, and he is not
    /// drawn rather than placed into it.
    var ready = true
    var report: ((MascotRoam.Report) -> Void)?
    /// Told the facing each roost decides.
    var face: ((MascotFacing) -> Void)?
    /// Told the pin a drag let go of him at.
    var pin: ((CGPoint) -> Void)?
    @Environment(\.look) private var look
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var port = MascotGlassPort()

    var body: some View {
        GeometryReader { proxy in
            let field = scene.field(in: proxy, keyboardTop: keyboardTop)
            let settings = MascotRoam.Settings(look.mascot, reduceMotion: reduceMotion)
            ZStack(alignment: .topLeading) {
                MascotOverChat(input: state.input, field: field, settings: settings,
                               interval: look.mascot.frameInterval, ready: ready,
                               conditions: .init(active: scenePhase == .active, opacity: opacity, covered: covered,
                                                 reduceMotion: reduceMotion),
                               report: report, face: face, pin: pin, glass: port)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                // On the glass, the stage is framed from the pane as laid out now, so SwiftUI
                // draws it wherever it draws the pane, in the same transaction.
                if look.mascot.placement == .glass, let field,
                   let stage = MascotPerch.glassStage(field, size: settings.size),
                   let slot = MascotPerch.glassSlot(field) {
                    // The flank clips from the top of his picture to the pane's foot.
                    let clip = CGRect(x: slot.minX, y: min(stage.minY, slot.maxY), width: slot.width,
                                      height: max(slot.maxY - stage.minY, 0))
                    ZStack(alignment: .topLeading) {
                        MascotGlassStage(port: port)
                            .frame(width: stage.width, height: stage.height)
                            .offset(x: stage.minX - clip.minX, y: stage.minY - clip.minY)
                    }
                    .frame(width: clip.width, height: clip.height, alignment: .topLeading)
                    .clipped()
                    .offset(x: clip.minX, y: clip.minY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .opacity(opacity)
        }
        // The canvas takes no touch of its own: a press on him is picked up by his recognizer on
        // the window, which is handed only touches on his box and off the well.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Topo laid over this view, which is the chat: where the look places him (`Look.Mascot.placement`)
    /// — roaming where the frames its turns, rows and glass report (`MascotScene`) leave him room,
    /// on the glass, or at a pin — taking no room of his own and no touch but a long press on him,
    /// and nothing to accessibility. Nil is no Topo. Until `ready` — the transcript read once — a
    /// roaming Topo is not drawn, and his first decision where to stand comes after it. `face` is
    /// told the facing each roost decides, for `Mascot.facing`, and `pin` the pin a drag let go of
    /// him at.
    func mascotRoams(_ state: MascotState?, opacity: Double = 1, covered: Bool = false, keyboardTop: CGFloat? = nil,
                     ready: Bool = true, report: ((MascotRoam.Report) -> Void)? = nil,
                     face: ((MascotFacing) -> Void)? = nil, pin: ((CGPoint) -> Void)? = nil) -> some View {
        overlayPreferenceValue(MascotScene.self) { scene in
            if let state {
                MascotLayer(state: state, scene: scene, opacity: opacity, covered: covered,
                            keyboardTop: keyboardTop, ready: ready, report: report, face: face, pin: pin)
            }
        }
    }
}
#endif

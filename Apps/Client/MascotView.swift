#if os(iOS)
import QuartzCore
import SwiftUI
import TopoMascot
import UIKit

/// Where Topo is drawn on the glass, worked out from the flank he lives in rather than from the
/// look alone: the look says how big, where and how far, and this clamps all of it to the room
/// the flank actually has, so no look and no screen puts him over the microphone.
///
/// Everything is in the space of the composer's row — the flanks and the well, inside the pane's
/// insets — where the leading flank is measured. The pane's leading end is `horizontalInset`
/// before the flank, the well's leading edge `spacing` after it, and the pane's top and foot the
/// vertical inset as drawn outside the row.
///
/// `share` is the share of its resting size the pane's microphone is drawn at
/// (`ComposerGeometry.scale`): under the keyboard the pane is short, and he is placed from the
/// short pane — its top edge and its foot — at his own size, which is `look.mascot.scale` alone
/// and never follows the pane's height.
struct MascotPlacement: Equatable, Sendable {
    /// The one rectangle he is drawn in and clipped to: from the pane's leading end to the well's
    /// leading edge, and from the top of him, floated as high as his bob goes, to the pane's foot.
    /// Nothing of him is drawn outside it, and it never reaches the well.
    var frame: CGRect
    /// Where his body stands in `frame`: the middle of the flank moved by the look's offset, on
    /// the row of the engine's shelf, which sits on the pane's top edge.
    var home: CGPoint
    /// Points to an art pixel.
    var scale: CGFloat
    /// How far the engine's idle stroll goes, in its own art pixels: towards the pane's leading
    /// end, and never past it.
    var corner: Double

    /// A flank with no room in it — a pane too narrow for anything but the microphone — draws
    /// nothing.
    var isEmpty: Bool { frame.width <= 0 || frame.height <= 0 }

    /// No placement at all: what a flank with no width gets.
    static let none = MascotPlacement(frame: .zero, home: .zero, scale: 1, corner: 0)

    static func of(flank: CGRect, row: CGSize, composer: Look.Composer, mascot: Look.Mascot,
                   share: CGFloat = 1) -> MascotPlacement {
        // No flank is no Topo: the inset and the spacing around a flank with no width are the
        // pane's edge and the well's margin, not room of his.
        guard flank.width > 0 else { return .none }
        let share = min(max(share, 0), 1)
        let scale = mascot.scale
        let inset = composer.verticalInset * share
        let left = flank.minX - composer.horizontalInset
        let right = max(left, flank.maxX + composer.spacing)
        let paneTop = -inset
        let paneFoot = row.height + inset
        let homeX = min(max((left + right) / 2 + mascot.offset.width, left), right)
        // The edge he stands on is between the pane's top edge and its foot, whatever the look
        // says: lifted above it he would float over the transcript, below it he is out of sight.
        let shelf = paneTop + min(max(mascot.offset.height, 0), paneFoot - paneTop)
        // Room above him for the bob, so a lift is drawn rather than clipped.
        let top = min(shelf - CGFloat(Topo.shelfY) * scale - max(mascot.bobAmplitude, 0), paneTop)
        let stroll = min(max(mascot.stroll, 0), homeX - left)
        return MascotPlacement(frame: CGRect(x: left, y: top, width: right - left, height: max(0, paneFoot - top)),
                               home: CGPoint(x: homeX - left, y: shelf - top), scale: scale,
                               corner: -Double(stroll / scale))
    }

    /// The engine's whole picture in `frame`'s space, with him walked `x` art pixels from home
    /// and floated `lift` points up off it.
    func sprite(x: Double, lift: CGFloat = 0) -> CGRect {
        CGRect(x: home.x + CGFloat(x - Topo.bodyX) * scale, y: home.y - CGFloat(Topo.shelfY) * scale - lift,
               width: CGFloat(Topo.width) * scale, height: CGFloat(Topo.height) * scale)
    }
}

/// Topo floating over an empty transcript. With no pane under him he is not standing on
/// anything, so he bobs where he would stand: up by as much as the amplitude and back, once a
/// period. The bob is scaled by how much of a pane there is not — the presence, which the pane
/// arrives at as the turns run under it — so as the glass appears he settles onto it rather than
/// stopping, and on the glass whole he is still.
struct MascotHover: Equatable, Sendable {
    var amplitude: CGFloat = 0
    var period: Double = 1
    /// The pane's presence, 0 to 1.
    var presence: Double = 1

    init(amplitude: CGFloat = 0, period: Double = 1, presence: Double = 1) {
        self.amplitude = amplitude
        self.period = period
        self.presence = presence
    }

    init(_ mascot: Look.Mascot, presence: Double) {
        self.init(amplitude: mascot.bobAmplitude, period: mascot.bobPeriod, presence: presence)
    }

    /// How far up he is `time` seconds into the bob, in points: nothing at the start of each
    /// period, the whole amplitude at its middle, and nothing at all under Reduce Motion, on the
    /// glass whole, or for a bob with no length or no period.
    func lift(at time: Double, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, period > 0, amplitude > 0, time.isFinite else { return 0 }
        let free = 1 - min(max(presence.isFinite ? presence : 1, 0), 1)
        let phase = (1 - cos(2 * .pi * time / period)) / 2
        return amplitude * CGFloat(free * phase)
    }
}

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
        /// How opaque his flank is drawn: the microphone's hold fades both flanks to
        /// `composer.flank.heldOpacity`. Any opacity above zero is him seen, so frames go on;
        /// at zero there is nothing to draw, and they stop.
        var opacity = 1.0
        /// A sheet is over the chat.
        var covered = false
        /// Reduce Motion: he is held still in his idle pose.
        var reduceMotion = false

        var visible: Bool { active && onScreen && opacity > 0 && !covered }
        /// Frames run: he is seen and may move.
        var animates: Bool { visible && !reduceMotion }
        /// One still frame, drawn once per state: he is seen and may not move.
        var still: Bool { visible && reduceMotion }
    }

    var conditions = Conditions() { didSet { if conditions != oldValue { holdStill() } } }
    /// What the engine is handed, including how far the stroll goes.
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
    /// model picks (`levelForModel`, by family, so two ids of one model are one head) and the band
    /// the tokens fall in (`loadForTokens`). Tokens moving within a band, a pose, a sign or the
    /// stroll's corner change nothing of the idle still, and `MascotState` sets nothing else it is
    /// drawn with: style, shading and relief are left at the engine's own.
    struct Still: Equatable {
        var level: Double
        var load: Load

        init(_ input: TopoInput) {
            let rest = Self.rest
            level = input.model.flatMap { $0.isEmpty ? nil : levelForModel($0) } ?? input.level ?? rest.level
            load = input.tokens.map(loadForTokens) ?? input.load.flatMap(Load.init(rawValue:)) ?? rest.load
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
    /// the pose has landed and drawn once, with the model and the load of the state.
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
        let sorted = spent.sorted(), n = sorted.count
        DebugRun.say(String(format: "mascot: %d frames, %@, mean %.2f ms, p95 %.2f ms, max %.2f ms",
                            n, input.activity ?? "idle", sorted.reduce(0, +) / Double(n),
                            sorted[n * 95 / 100], sorted[n - 1]))
        spent.removeAll(keepingCapacity: true)
    }
    #endif
}

/// The view he is drawn in: one layer holding the engine's picture, magnified nearest-neighbour,
/// moved along the shelf as he strolls, and clipped to the canvas, which is his placement's frame.
/// It takes no touch and is nothing to accessibility, so the microphone beside it is found and
/// pressed exactly as it would be without him.
@MainActor
final class MascotCanvas: UIView {
    let driver = MascotDriver()
    private let sprite = CALayer()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var placement: MascotPlacement?
    private var interval = 1.0 / 30
    private(set) var hover = MascotHover()
    /// How long he has been drawn moving, which is where in the bob he is.
    private var clock = 0.0

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
        sprite.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "frame": NSNull()]
        layer.addSublayer(sprite)
        driver.onFrame = { [weak self] image, x in self?.show(image, x: x) }
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    /// Everything the view is told by SwiftUI, applied at once.
    func apply(input: TopoInput, placement: MascotPlacement, interval: Double, hover: MascotHover = .init(),
               conditions: MascotDriver.Conditions) {
        self.placement = placement
        self.interval = interval
        self.hover = hover
        var conditions = conditions
        conditions.onScreen = window != nil
        driver.input = input
        driver.conditions = conditions
        reschedule()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.frame = placement.sprite(x: lastX, lift: lift)
        CATransaction.commit()
    }

    /// How far up the bob has him now: nothing under Reduce Motion, where no frame moves him.
    var lift: CGFloat { hover.lift(at: clock, reduceMotion: driver.conditions.reduceMotion) }

    /// Where his picture is drawn in the canvas, as the last frame or state left it.
    var spriteFrame: CGRect { sprite.frame }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        driver.conditions.onScreen = window != nil
        reschedule()
    }

    private var lastX = 0.0

    private func show(_ image: CGImage, x: Double) {
        lastX = x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = image
        if let placement { sprite.frame = placement.sprite(x: x, lift: lift) }
        CATransaction.commit()
    }

    /// The link runs while he animates and not a frame longer.
    private func reschedule() {
        if driver.conditions.animates {
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

    fileprivate func fire(_ link: CADisplayLink) {
        // The first frame after a pause moves him one frame on, not by the whole pause.
        let dt = last == 0 ? interval : min(link.targetTimestamp - last, 0.1)
        last = link.targetTimestamp
        step(dt)
    }

    /// One frame, `dt` seconds on: the bob's clock and the engine moved on together.
    func step(_ dt: Double) {
        clock += dt
        driver.tick(dt)
    }

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

/// The canvas in SwiftUI.
struct MascotPerch: UIViewRepresentable {
    var input: TopoInput
    var placement: MascotPlacement
    var interval: Double
    var hover: MascotHover
    var conditions: MascotDriver.Conditions

    func makeUIView(context: Context) -> MascotCanvas { MascotCanvas(frame: .zero) }

    func updateUIView(_ canvas: MascotCanvas, context: Context) {
        canvas.apply(input: input, placement: placement, interval: interval, hover: hover, conditions: conditions)
    }

    static func dismantleUIView(_ canvas: MascotCanvas, coordinator: ()) {
        canvas.driver.conditions.onScreen = false
    }
}

/// Topo in the composer's leading flank: placed from the flank's measured bounds and the row's
/// size, drawn from the state he is handed, and told what decides whether he is drawn.
///
/// The presence and the share are animated through it, so the bob eases out over the same time
/// the pane's surface arrives in, and his slot moves with the short pane's edges rather than
/// jumping. His size is the look's and does not move at all.
struct MascotOnGlass: View, Animatable {
    let state: MascotState
    let flank: CGRect
    let row: CGSize
    /// The share the pane's microphone is drawn at (`ComposerGeometry.scale`).
    var share: CGFloat = 1
    /// The pane's presence: at nothing he floats, and he settles as it rises.
    var presence: Double = 1
    /// How opaque his flank is drawn; frames stop only at zero.
    let opacity: Double
    /// A sheet is over the chat.
    let covered: Bool
    @Environment(\.look) private var look
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The presence and the share, animated together: the bob eases out as the pane arrives, and
    /// his slot follows the pane's edges as the keyboard rises rather than jumping.
    nonisolated var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(presence, share) }
        set {
            presence = newValue.first
            share = newValue.second
        }
    }

    var body: some View {
        let placement = MascotPlacement.of(flank: flank, row: row, composer: look.composer, mascot: look.mascot,
                                           share: share)
        if !placement.isEmpty {
            MascotPerch(input: input(corner: placement.corner), placement: placement,
                        interval: look.mascot.frameInterval,
                        hover: MascotHover(look.mascot, presence: presence),
                        conditions: .init(active: scenePhase == .active, opacity: opacity, covered: covered,
                                          reduceMotion: reduceMotion))
                .frame(width: placement.frame.width, height: placement.frame.height)
                .position(x: placement.frame.midX, y: placement.frame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func input(corner: Double) -> TopoInput {
        var input = state.input
        input.corner = corner
        return input
    }
}
#endif

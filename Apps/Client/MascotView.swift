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

/// The view he is drawn in, laid over the whole of the chat: one layer holding the engine's
/// whole picture, magnified nearest-neighbour and put so that the part he takes up at rest
/// (`MascotSprite.box`) is where his roam says he is; what a pose draws past that box is drawn
/// over whatever is there. It takes no touch and is nothing to
/// accessibility, so everything under it is found and pressed exactly as it would be without him.
@MainActor
final class MascotCanvas: UIView {
    let driver = MascotDriver()
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
        layer.addSublayer(sprite)
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
        if let field { roam.observe(field, at: clock) }
        self.roam = roam
        sync()
    }

    /// His box where the roam has it now, in the canvas: what the roost holds.
    var spriteFrame: CGRect { roam?.picture ?? .zero }
    /// The whole of the engine's picture as the layer draws it, round that box.
    var drawnFrame: CGRect { sprite.frame }
    /// Whether he is being drawn at all.
    var showing: Bool { sprite.opacity > 0 }

    override func didMoveToWindow() {
        super.didMoveToWindow()
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
            || driver.input.tokens != worn.tokens || driver.input.sign != worn.sign || driver.input.corner != 0 {
            driver.input = worn
        }
        driver.conditions = conditions
        reschedule()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let picture = roam.picture { sprite.frame = MascotSprite.drawn(around: picture) }
        sprite.opacity = roam.hidden ? 0 : 1
        CATransaction.commit()
        report(roam)
    }

    private func report(_ roam: MascotRoam) {
        guard let onReport else { return }
        var now = roam.report
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
        roam?.advance(to: clock)
        sync()
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
        /// Counts the reports the canvas has made, one more each time, so a reader polling the
        /// latest can tell it missed none.
        var sequence = 0
        /// The last reports, oldest first, each as its sequence, his frame, the pane and whether
        /// he stood nowhere: a reader polling the latest report sees every frame in between.
        var recent: [Glimpse] = []

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
                      pane: field?.pane.map(numbers))
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

    func makeUIView(context: Context) -> MascotCanvas { MascotCanvas(frame: .zero) }

    func updateUIView(_ canvas: MascotCanvas, context: Context) {
        canvas.onReport = report
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
    @Environment(\.look) private var look
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            MascotOverChat(input: state.input, field: scene.field(in: proxy, keyboardTop: keyboardTop),
                           settings: MascotRoam.Settings(look.mascot, reduceMotion: reduceMotion),
                           interval: look.mascot.frameInterval, ready: ready,
                           conditions: .init(active: scenePhase == .active, opacity: opacity, covered: covered,
                                             reduceMotion: reduceMotion),
                           report: report)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .opacity(opacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Topo laid over this view, which is the chat: he stands where the frames its turns, rows and
    /// glass report (`MascotScene`) leave him room, takes no room of his own and no touch, and is
    /// nothing to accessibility. Nil is no Topo. Until `ready` — the transcript read once — he is
    /// not drawn, and his first decision where to stand comes after it.
    func mascotRoams(_ state: MascotState?, opacity: Double = 1, covered: Bool = false, keyboardTop: CGFloat? = nil,
                     ready: Bool = true, report: ((MascotRoam.Report) -> Void)? = nil) -> some View {
        overlayPreferenceValue(MascotScene.self) { scene in
            if let state {
                MascotLayer(state: state, scene: scene, opacity: opacity, covered: covered,
                            keyboardTop: keyboardTop, ready: ready, report: report)
            }
        }
    }
}
#endif

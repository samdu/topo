#if os(iOS)
import AVFoundation
import Foundation

/// The microphone's engine, off the main actor: the input `AVAudioEngine`, its input node and its
/// tap are touched only on this object's serial queue, so the press's open (the engine made,
/// voice processing, the formats, the tap, `prepare`, `start`) never holds the main thread the
/// gesture's events and the long press's verdict arrive on.
///
/// What runs where: `VoiceInput` (the main actor) claims and activates the audio session, which is
/// the main actor's and the speaker's state too, then hands the open here as one block, and every
/// teardown it makes is a `queue.sync`, so a teardown returns only once the tap is off and the
/// engine stopped. One made while an open is in flight waits for the open's block, which is
/// bounded by the open itself. Nothing here calls back to the main actor, so a sync from it cannot
/// wait on itself.
final class InputEngine: @unchecked Sendable {
    /// The numbers one side of an input node reports, which is all the guard judges on.
    typealias Format = VoiceInput.Format
    /// What makes an engine, reads its two formats and sets its voice processing: the system's in
    /// production, the suite's seams in a test. Called on the queue only.
    typealias Make = @Sendable () -> AVAudioEngine
    typealias Formats = @Sendable (AVAudioEngine) -> (client: AVAudioFormat, hardware: AVAudioFormat)
    typealias Processing = @Sendable (AVAudioEngine, Bool) throws -> Void

    private let queue = DispatchQueue(label: "zone.hexagon.topo.input", qos: .userInitiated)
    private let make: Make
    private let formats: Formats
    private let processing: Processing
    // Queue-confined.
    private var engine: AVAudioEngine?
    private var tapped = false
    /// The media services resets seen, counted on the posting thread at the notification itself,
    /// so the open's block can see one that lands while it runs.
    private let resetMark = Counter()
    private let center: NotificationCenter
    private var resetObserver: NSObjectProtocol?

    init(center: NotificationCenter, make: @escaping Make, formats: @escaping Formats,
         processing: @escaping Processing) {
        self.make = make
        self.formats = formats
        self.processing = processing
        self.center = center
        let mark = resetMark
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { _ in mark.bump() }
    }

    deinit {
        if let resetObserver { center.removeObserver(resetObserver) }
    }

    /// The reset count to hand an open, read before the session is made active for it.
    var resets: Int { resetMark.value }

    /// What an open made: the formats the guard judged, and how long each step took.
    struct Opened: Sendable {
        var client: Format
        var hardware: Format
        var steps: String
    }

    /// The input could not be opened, with the reason the press's refusal names.
    enum Refusal: Error, Sendable {
        /// A dead format on either side, or two rates that differ: both are ways `installTap`
        /// raises an exception no `catch` sees.
        case noInput
        /// The input node would not take the voice processing asked for.
        case processing(on: Bool, underlying: any Error)
        /// A media services reset landed since the session was made active for this open: the
        /// handles it would make are dead.
        case reset
        /// `start()` threw.
        case start(any Error)

        /// The session under the input is dead, not only this engine: no input, or a reset.
        var deadSession: Bool {
            switch self {
            case .noInput, .reset: true
            case .processing, .start: false
            }
        }
    }

    /// Opens the microphone off the main actor, in the one order that is safe: the engine made
    /// (or the kept one taken), voice processing set to `suppress` on an engine that is not
    /// running, the formats read once, the guard, the tap installed with the very format object
    /// the guard judged, `prepare`, `start`. `resetsAt` is `resets` as read before the session was
    /// made active; a reset since refuses before the engine, the tap and the start. A refusal leaves
    /// nothing running: the tap off and the engine stopped, and dropped where its state is in doubt.
    ///
    /// Put on the queue by the caller, synchronously, before it suspends: a teardown the caller
    /// makes after this returns is behind the open on the queue, so its `stop` waits for it and
    /// stops what it started. `done` is called on the queue.
    func enqueueOpen(suppress: Bool, resetsAt: Int, tap: Tap, done: @escaping @Sendable (Result<Opened, Error>) -> Void) {
        // From the main actor, where every teardown is made: on any other thread the open could
        // reach the queue after a teardown the main actor made since.
        dispatchPrecondition(condition: .onQueue(.main))
        queue.async {
            done(Result { try self.openHere(suppress: suppress, resetsAt: resetsAt, tap: tap) })
        }
    }

    /// The same open, waited for: a resume, whose caller reads its answer at once.
    func openNow(suppress: Bool, resetsAt: Int, tap: Tap) throws -> Opened {
        try queue.sync { try openHere(suppress: suppress, resetsAt: resetsAt, tap: tap) }
    }

    /// What the tap hands its buffers to: the gate they pass through and the sink they reach.
    struct Tap: @unchecked Sendable {
        let gate: TapGate
        let sink: SampleSink
        #if DEBUG
        let meter: TapMeter
        #endif
    }

    private func openHere(suppress: Bool, resetsAt: Int, tap: Tap) throws -> Opened {
        dispatchPrecondition(condition: .onQueue(queue))
        let clock = ContinuousClock()
        var mark = clock.now
        var steps: [String] = []
        func step(_ name: String) {
            let now = clock.now
            let ms = (now - mark).components
            steps.append("\(name) \(ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000) ms")
            mark = now
        }
        do {
            guard resetMark.value == resetsAt else { throw Refusal.reset }
            let engine = engine ?? {
                let made = make()
                self.engine = made
                return made
            }()
            let input = engine.inputNode
            step("engine")
            // Before the formats, because voice processing changes them, and on an engine that is
            // not running, which every open finds: a release and a teardown both stop it.
            do { try processing(engine, suppress) } catch { throw Refusal.processing(on: suppress, underlying: error) }
            step("voice processing")
            // Read once. The format the tap is installed with is the very object the guard
            // judged: a route change between two reads would pass the guard on the first numbers
            // and raise on the second.
            let (format, hardware) = formats(engine)
            let client = Format(format)
            // A dead format means the session has no input right now, and a tap rate that is not
            // the hardware's is the other way `installTap` raises; both are uncatchable.
            guard VoiceInput.inputIsUsable(client: client, hardware: Format(hardware)) else { throw Refusal.noInput }
            guard resetMark.value == resetsAt else { throw Refusal.reset }
            input.removeTap(onBus: 0)
            tapped = true
            let gate = tap.gate
            let sink = tap.sink
            #if DEBUG
            let meter = tap.meter
            #endif
            // The tap block is `@Sendable`, and it is load-bearing: it runs on the audio thread,
            // and a closure formed in an actor-isolated context without it is isolated by
            // inference, which Swift 6 opens with an executor check that traps off that
            // executor (`dispatch_assert_queue` under `swift_task_isCurrentExecutor`), past any
            // `catch`.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
                gate.pass {
                    #if DEBUG
                    meter.record(buffer)
                    #endif
                    sink.append(buffer)
                }
            }
            step("formats and tap")
            // Apple's own warm-up: what `start()` would otherwise do first.
            engine.prepare()
            step("prepare")
            guard resetMark.value == resetsAt else { throw Refusal.reset }
            do { try engine.start() } catch { throw Refusal.start(error) }
            step("start")
            return Opened(client: client, hardware: Format(hardware), steps: steps.joined(separator: ", "))
        } catch {
            stopHere()
            switch error {
            case Refusal.processing, Refusal.reset, Refusal.noInput: engine = nil
            default: break
            }
            throw error
        }
    }

    /// The tap off and the engine stopped, the engine kept for the next open. Returns once both
    /// are done; free when nothing runs.
    func stop() { queue.sync { stopHere() } }

    /// Stopped, and the engine dropped: a reset, a dead input or an engine whose state is in doubt.
    func drop() {
        queue.sync {
            stopHere()
            engine = nil
        }
    }

    /// Whether the input engine is running: a session's, or one kept past its release.
    var isRunning: Bool { queue.sync { engine?.isRunning == true } }
    /// Whether a tap is on the input node.
    var isTapped: Bool { queue.sync { tapped } }

    private func stopHere() {
        if tapped {
            tapped = false
            engine?.inputNode.removeTap(onBus: 0)
        }
        if engine?.isRunning == true { engine?.stop() }
    }

    /// A count under a lock, bumped from any thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func bump() { lock.withLock { count += 1 } }
    }
}
#endif

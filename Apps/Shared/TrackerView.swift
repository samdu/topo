#if os(iOS)
import SwiftUI

/// The pizza tracker: a progress tracker's card drawn for a Live Activity's regions, the same on
/// the lock screen, in the Dynamic Island and in the app's own host, where the snapshot suite
/// draws it. Every value it draws was judged where it was read (`ProgressTracker.read`,
/// `TrackerCard`); here they are only drawn. Nothing animates with time: the running segment is a
/// static style, so a picture of it is the same at every phase.
struct TrackerView: View {
    enum Form { case lockScreen, expanded, compactLeading, compactTrailing, minimal }

    let card: TrackerCard
    let form: Form
    /// The system's word that the content is past its stale date: the activity reads how long ago
    /// it was updated rather than as current.
    var stale = false
    var tint: Color?
    /// A fixed now: the relative times are then written once against it rather than ticking,
    /// which is how a snapshot of the view is the same picture every time. The extension gives
    /// none.
    var clock: Date?

    static let barHeight: CGFloat = 6
    static let barSpacing: CGFloat = 3
    static let ringLine: CGFloat = 3
    static let ringSize: CGFloat = 20
    static let rowSpacing: CGFloat = 6

    var body: some View {
        switch form {
        case .lockScreen, .expanded: full
        case .compactLeading: ring.frame(width: Self.ringSize, height: Self.ringSize)
        case .compactTrailing: count
        case .minimal: ring.frame(width: Self.ringSize, height: Self.ringSize)
        }
    }

    private var accent: Color { tint ?? Theme.primary }

    private var full: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: card.title)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("tracker-title")
                Spacer(minLength: 8)
                count
            }
            bar
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: card.focus?.label ?? "")
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .accessibilityIdentifier("tracker-focus")
                Spacer(minLength: 8)
                estimate
            }
            if !card.note.isEmpty {
                Text(verbatim: card.note)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .accessibilityIdentifier("tracker-note")
            }
        }
    }

    /// One segment a step, in the order of the steps.
    private var bar: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(Array(card.steps.enumerated()), id: \.offset) { _, step in
                segment(step.state).frame(height: Self.barHeight)
            }
        }
        .accessibilityIdentifier("tracker-bar")
        .accessibilityLabel("\(card.past) of \(card.steps.count) steps done")
    }

    /// A skipped step is behind the bar and counted, so it is drawn in the tint like a done one,
    /// as an outline: filled it would read as done, dim it would read as waiting.
    @ViewBuilder
    private func segment(_ state: ProgressTracker.Step.State) -> some View {
        switch state {
        case .skipped: Capsule().strokeBorder(accent.opacity(0.7), lineWidth: 1)
        default: Capsule().fill(colour(state))
        }
    }

    func colour(_ state: ProgressTracker.Step.State) -> Color {
        switch state {
        case .done: accent
        case .running: accent.opacity(0.45)
        case .failed: Theme.signal
        case .skipped: accent.opacity(0.7)
        case .waiting: Theme.border
        }
    }

    /// "3 of 7", or the end: a tick, or the failure mark.
    @ViewBuilder
    private var count: some View {
        switch card.state {
        case .running:
            Text(verbatim: "\(card.past) of \(card.steps.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .accessibilityIdentifier("tracker-count")
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(accent)
                .accessibilityLabel("done")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.signal)
                .accessibilityLabel("failed")
        }
    }

    /// The estimate while it runs, how long ago it ended, or how long since the last word when
    /// the system says the content is stale.
    @ViewBuilder
    private var estimate: some View {
        Group {
            switch Self.estimate(card, stale: stale) {
            case .stale(let updated):
                (Text(verbatim: "updated ") + relative(updated) + Text(verbatim: " ago")).foregroundStyle(Theme.signal)
            case .ended(let failed, let ended):
                (Text(verbatim: failed ? "failed " : "done ") + relative(ended) + Text(verbatim: " ago")).foregroundStyle(Theme.textMuted)
            case .eta(let eta):
                (Text(verbatim: "about ") + relative(eta)).foregroundStyle(Theme.textMuted)
            case .updated(let updated):
                (Text(verbatim: "updated ") + relative(updated) + Text(verbatim: " ago")).foregroundStyle(Theme.textMuted)
            }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .accessibilityIdentifier("tracker-estimate")
    }

    /// Which estimate the trailing text is: stale first, since the system's word outranks the card's.
    enum Estimate: Equatable {
        case stale(Date)
        case ended(failed: Bool, Date)
        case eta(Date)
        case updated(Date)
    }

    static func estimate(_ card: TrackerCard, stale: Bool) -> Estimate {
        if stale { return .stale(card.updated) }
        if let ended = card.ended, card.state != .running { return .ended(failed: card.state == .failed, ended) }
        if let eta = card.eta, eta > card.updated { return .eta(eta) }
        return .updated(card.updated)
    }

    private func relative(_ date: Date) -> Text {
        guard let clock else { return Text(date, style: .relative) }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        return Text(verbatim: formatter.string(from: abs(date.timeIntervalSince(clock))) ?? "")
    }

    /// The bar as a ring, for the island's small forms.
    private var ring: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: Self.ringLine)
            Circle()
                .trim(from: 0, to: card.fraction)
                .stroke(card.state == .failed ? Theme.signal : accent, style: StrokeStyle(lineWidth: Self.ringLine, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityLabel("\(card.past) of \(card.steps.count) steps done")
    }
}

/// One region of a Topo activity, drawn from its state: the region's own tree where the layout has
/// one, else the tracker design where there is a card, else the mark. What the extension and the
/// app's host both draw.
struct ActivityRegionView: View {
    let region: ActivityRegion
    let slot: String
    let state: ActivityState
    var stale = false

    /// The most the island's small regions take, in points: Apple's Live Activities
    /// specifications (Human Interface Guidelines, *Specifications*, iOS dimensions) give a compact
    /// leading or trailing region 52.33 by 36.67 on a 393-point-wide phone and 62.33 by 36.67 on a
    /// 430-point one, and the minimal 36.67 to 45 by 36.67; the smaller phone's compact figure fits
    /// both. A view that takes all the width it is offered — a timer's `Text` does — is otherwise
    /// handed the island's whole width and stretches it across the screen.
    static let compactBound = CGSize(width: 52.33, height: 36.67)
    static let minimalBound = CGSize(width: 45, height: 36.67)

    /// The bound a region is drawn within, nil for the lock screen and the expanded island, which
    /// the system lays out at their full width.
    static func bound(_ region: ActivityRegion) -> CGSize? {
        switch region {
        case .islandCompactLeading, .islandCompactTrailing: compactBound
        case .islandMinimal: minimalBound
        case .lockScreen, .islandExpanded: nil
        }
    }

    var body: some View {
        if let bound = Self.bound(region) {
            content
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: bound.width, maxHeight: bound.height)
                .clipped()
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let layout = state.layout.map(ActivityLayout.read) ?? ActivityLayout()
        if let node = layout.regions[region] {
            WidgetNodeView(node: node, context: WidgetContext(slot: slot, revision: 0, family: .accessoryRectangular))
        } else if let card = state.card {
            TrackerView(card: card, form: Self.form(region), stale: stale, tint: layout.tint?.color)
        } else {
            switch region {
            case .lockScreen, .islandExpanded:
                HStack(spacing: 8) {
                    OctopusMark().frame(width: 24, height: 24)
                    Text(verbatim: "Topo").font(.headline).foregroundStyle(Theme.text)
                }
            case .islandCompactLeading, .islandCompactTrailing, .islandMinimal:
                OctopusMark().frame(width: TrackerView.ringSize, height: TrackerView.ringSize)
            }
        }
    }

    static func form(_ region: ActivityRegion) -> TrackerView.Form {
        switch region {
        case .lockScreen: .lockScreen
        case .islandExpanded: .expanded
        case .islandCompactLeading: .compactLeading
        case .islandCompactTrailing: .compactTrailing
        case .islandMinimal: .minimal
        }
    }
}
#endif

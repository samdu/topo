import SwiftUI
import TopoCore

/// The transcript, read-only, on whatever screen it is given. The phone, the
/// watch and the TV all show the same turns in the same order; what changes
/// between them is the type size and how far the turns are from the edges.
struct TranscriptView: View {
    let turns: [Turn]
    var notice: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.spacing) {
                    if let notice {
                        Text(notice)
                            .font(Metrics.noticeFont)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(turns) { turn in
                        TurnRow(turn: turn).id(turn.ref)
                    }
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, Metrics.spacing)
                .frame(maxWidth: Metrics.maximumLineWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: turns.last?.ref) { _, _ in scroll(proxy, animated: true) }
        }
    }

    /// The newest turn is the one worth seeing, so the transcript opens at
    /// the end and follows it.
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = turns.last?.ref else { return }
        if animated {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

/// One turn: who said it, when, and what.
struct TurnRow: View {
    let turn: Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(turn.role == .assistant ? "TOPO" : "YOU")
                    .font(Metrics.labelFont)
                    .foregroundStyle(turn.role == .assistant ? AnyShapeStyle(Theme.teal) : AnyShapeStyle(.secondary))
                Spacer(minLength: 8)
                Text(turn.at, format: .dateTime.hour().minute())
                    .font(Metrics.labelFont)
                    .foregroundStyle(.secondary)
            }
            Text(turn.text)
                .font(Metrics.bodyFont)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(tvOS)
        // The remote scrolls a tvOS list by moving focus, so every turn has
        // to be somewhere focus can land.
        .focusable()
        #endif
    }
}

/// What differs between a watch, a phone and a television is the size of the
/// type and how much room the turns get. The transcript itself does not.
enum Metrics {
    #if os(watchOS)
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 2
    static let maximumLineWidth: CGFloat = .infinity
    static let labelFont = Font.system(.caption2).weight(.semibold)
    static let bodyFont = Font.system(.footnote)
    static let noticeFont = Font.system(.caption2)
    #elseif os(tvOS)
    static let spacing: CGFloat = 24
    static let horizontalPadding: CGFloat = 48
    static let maximumLineWidth: CGFloat = 1100
    static let labelFont = Font.system(.caption).weight(.semibold)
    static let bodyFont = Font.system(.title3)
    static let noticeFont = Font.system(.caption)
    #else
    static let spacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 16
    static let maximumLineWidth: CGFloat = 672
    static let labelFont = Font.system(.caption).weight(.semibold)
    static let bodyFont = Font.system(.body)
    static let noticeFont = Font.system(.caption)
    #endif
}

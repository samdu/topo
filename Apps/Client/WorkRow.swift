#if os(iOS)
import SwiftUI

/// What the guest did between a person's turn and its reply, under that turn, at three depths.
///
/// Closed it is one quiet line: a chevron, a glyph per step and the count of calls. The glyphs
/// are too small to be targets of their own, so the line opens and closes as one. Open, it is a
/// line per step: a thought, or a call's name and summary with its outcome once that lands. Each
/// of those lines opens in turn to the step in full: the thought's text, or the call's input and
/// what came back. A long part shows its head and opens whole on a sheet, so the transcript's
/// scroll never holds a second vertical scroll inside it.
///
/// Each depth is a `DisclosureGroup`, drawn by `WorkDisclosure` so the chevron leads and the
/// whole label is the target. The row is its own view under the turn and never a gesture on a
/// reply's words. While the turn runs the row is live: steps join it as they happen and an
/// outcome lands on its line in place.
struct WorkRow: View {
    let steps: [WorkStep]
    let live: Bool
    @Environment(\.look) private var look
    @State private var open = false
    @State private var opened: Set<String> = []

    var body: some View {
        DisclosureGroup(isExpanded: $open.animation(.easeOut(duration: look.work.opening))) {
            VStack(alignment: .leading, spacing: look.work.spacing) {
                ForEach(steps) { line($0) }
            }
            .padding(.leading, look.work.indent)
        } label: {
            closed
        }
        .disclosureGroupStyle(WorkDisclosure(spacing: look.work.spacing))
        .accessibilityIdentifier("work-row")
    }

    private var closed: some View {
        HStack(spacing: look.work.glyphSpacing) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(look.work.chevronFont)
            ForEach(Array(steps.prefix(look.work.glyphsShown))) { step in
                Text(step.glyph)
                    .font(look.work.glyphFont)
                    .overlay(alignment: .bottomTrailing) {
                        if step.outcome?.ok == false {
                            Rectangle().fill(look.work.failed).frame(width: look.work.failedMark, height: look.work.failedMark)
                        }
                    }
            }
            if steps.count > look.work.glyphsShown { Text("+\(steps.count - look.work.glyphsShown)") }
            if live { ProgressView().controlSize(.mini) }
            Text(count)
            Spacer(minLength: 0)
        }
        .font(look.work.font)
        .foregroundStyle(look.work.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count)
        .accessibilityHint(open ? "Collapse" : "Expand")
    }

    private var count: String {
        let calls = steps.filter(\.isCall).count
        if calls == 0 { return steps.count == 1 ? "1 step" : "\(steps.count) steps" }
        return calls == 1 ? "1 call" : "\(calls) calls"
    }

    private func line(_ step: WorkStep) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { opened.contains(step.id) },
            set: { now in withAnimation(.easeOut(duration: look.work.opening)) { if now { opened.insert(step.id) } else { opened.remove(step.id) } } }
        )) {
            WorkStepDetail(step: step, live: live)
        } label: {
            summary(step)
        }
        .disclosureGroupStyle(WorkDisclosure(spacing: look.work.spacing))
        .accessibilityIdentifier("work-step-\(step.id)")
    }

    private func summary(_ step: WorkStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: look.work.lineSpacing) {
            Text(step.glyph).font(look.work.glyphFont)
            switch step.kind {
            case .thought:
                Text("thought")
            case .call(let name, let summary, _):
                (Text(name).fontWeight(.semibold) + Text(summary.isEmpty ? "" : " — \(summary)"))
                    .lineLimit(2)
            }
            Spacer(minLength: look.work.glyphSpacing)
            if let outcome = step.outcome {
                Text(outcome.ok ? "✓ \(WorkStepDetail.size(outcome.bytes))" : "✗")
                    .foregroundStyle(outcome.ok ? look.work.ink : look.work.failed)
            } else if step.isCall, live {
                Text("…")
            }
        }
        .font(look.work.font)
        .foregroundStyle(look.work.ink)
    }
}

/// A `DisclosureGroup` as the work row draws one: the label is the whole target, its chevron
/// (where it has one) its own to draw, and the content under it.
struct WorkDisclosure: DisclosureGroupStyle {
    let spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Button { configuration.isExpanded.toggle() } label: {
                configuration.label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded { configuration.content.transition(.opacity) }
        }
    }
}

/// One step opened: a thought's text, or a call's input and its result, each part whole when it
/// is short and its head with "show all" when it is not.
struct WorkStepDetail: View {
    let step: WorkStep
    let live: Bool
    @Environment(\.look) private var look
    @State private var full: Part?

    struct Part: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: look.work.spacing) {
            switch step.kind {
            case .thought(let text):
                if let text { part("thought", text) }
                else { note("The model thought here and kept no words of it.") }
            case .call(_, _, let input):
                part("input", input.isEmpty ? "(none)" : input)
                if let outcome = step.outcome {
                    part(outcome.ok ? "result · \(Self.size(outcome.bytes))" : "error · \(Self.size(outcome.bytes))",
                         outcome.text.isEmpty ? "(empty)" : outcome.text, failed: !outcome.ok)
                } else {
                    note(live ? "running…" : "No result came back.")
                }
            }
        }
        .padding(look.work.detailPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(look.work.detailBackground)
        .overlay(alignment: .leading) { Rectangle().fill(look.work.accent).frame(width: look.work.ruleWidth) }
        .sheet(item: $full) { WorkFullText(part: $0) }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(look.work.detailFont).foregroundStyle(look.work.ink)
    }

    private func part(_ title: String, _ text: String, failed: Bool = false) -> some View {
        let (head, cut) = Self.head(text, characters: look.work.inlineCharacters, lines: look.work.inlineLines)
        return VStack(alignment: .leading, spacing: look.work.headingSpacing) {
            Text(title.uppercased())
                .font(look.work.headingFont)
                .foregroundStyle(failed ? look.work.failed : look.work.ink)
            Text(head)
                .font(look.work.detailFont)
                .foregroundStyle(look.work.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if cut {
                Button("show all") { full = Part(title: title, text: text) }
                    .font(look.work.headingFont)
                    .foregroundStyle(look.work.accent)
                    .buttonStyle(.plain)
            }
        }
    }

    /// The first `lines` lines of `text`, within `characters`, and whether that left any out.
    static func head(_ text: String, characters: Int, lines: Int) -> (String, Bool) {
        var kept = text.prefix(characters)
        var seen = 0
        if let end = kept.firstIndex(where: { c in
            if c == "\n" { seen += 1 }
            return seen >= lines
        }) {
            kept = kept[..<end]
        }
        guard kept.endIndex < text.endIndex else { return (text, false) }
        return (kept.trimmingCharacters(in: .newlines) + "\n…", true)
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A step's part in full on its own sheet: the one place a long result scrolls.
private struct WorkFullText: View {
    let part: WorkStepDetail.Part
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(part.text)
                    .font(look.work.detailFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(look.work.detailPadding)
            }
            .navigationTitle(part.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
#endif

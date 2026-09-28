#if os(iOS)
import AppIntents
import SwiftUI
#if canImport(TopoMascot)
import TopoMascot
#endif

/// What a node is drawn in: the slot it belongs to and the revision its controls carry, the family
/// it is drawn for, the slot's images, and whether its words are the person's conversation.
struct WidgetContext: Sendable {
    var slot: String
    var revision: Int
    var family: WidgetFamilyName
    var images: [String: Data] = [:]
    /// The words are a reply's, so they are redacted where the person's settings say to
    /// (`.privacySensitive()`). The default's home-screen families; never relied on alone.
    var privateText = false
}

/// The one switch from a node to what draws it, the same on the home screen, on the lock screen
/// and in the app's own debug host (`WidgetHostView`).
///
/// Every text and every control carries an accessibility identifier from its place in the tree
/// (`widget-text-0.1`, `widget-control-<id>`), which is what the hosted UI suite finds each by.
struct WidgetNodeView: View {
    let node: WidgetNode
    let context: WidgetContext
    /// Where this node is, as child indexes from the root.
    var path = "0"

    var body: some View {
        switch node {
        case .stack(let stack): stackView(stack)
        case .text(let text): textView(text)
        case .glyph(let glyph): glyphView(glyph)
        case .image(let image): imageView(image)
        case .gauge(let gauge): gaugeView(gauge)
        case .progress(let progress):
            // A capacity gauge rather than a `ProgressView`, which draws as UIKit's own bar and
            // which no renderer but the system's can draw.
            Gauge(value: progress.value) { EmptyView() }
                .gaugeStyle(.linearCapacity)
                .tint(progress.colour?.color ?? Theme.highlight)
        case .topo(let pose):
            // Pictures take the room the words and the controls leave.
            WidgetMascotView(pose: pose).layoutPriority(-1)
        case .spacer(let min): Spacer(minLength: min)
        case .divider: Divider()
        case .control(let control): controlView(control)
        }
    }

    private func child(_ node: WidgetNode, _ index: Int) -> WidgetNodeView {
        WidgetNodeView(node: node, context: context, path: "\(path).\(index)")
    }

    @ViewBuilder
    private func stackView(_ stack: WidgetNode.Stack) -> some View {
        let spacing = stack.spacing.map { CGFloat($0) }
        switch stack.axis {
        case .vstack:
            VStack(alignment: Self.horizontal[stack.alignment] ?? .center, spacing: spacing) {
                ForEach(Array(stack.children.enumerated()), id: \.offset) { index, node in child(node, index) }
            }
        case .hstack:
            HStack(alignment: Self.vertical[stack.alignment] ?? .center, spacing: spacing) {
                ForEach(Array(stack.children.enumerated()), id: \.offset) { index, node in child(node, index) }
            }
        case .zstack:
            ZStack(alignment: Self.both[stack.alignment] ?? .center) {
                ForEach(Array(stack.children.enumerated()), id: \.offset) { index, node in child(node, index) }
            }
        }
    }

    static let horizontal: [String: HorizontalAlignment] = ["leading": .leading, "center": .center, "trailing": .trailing]
    static let vertical: [String: VerticalAlignment] = [
        "top": .top, "center": .center, "bottom": .bottom,
        "firstTextBaseline": .firstTextBaseline, "lastTextBaseline": .lastTextBaseline,
    ]
    static let both: [String: Alignment] = [
        "topLeading": .topLeading, "top": .top, "topTrailing": .topTrailing, "leading": .leading,
        "center": .center, "trailing": .trailing, "bottomLeading": .bottomLeading, "bottom": .bottom,
        "bottomTrailing": .bottomTrailing,
    ]

    private func textView(_ text: WidgetNode.Text) -> some View {
        words(text)
            .font(.system(Self.styles[text.style] ?? .body, design: Self.designs[text.design] ?? .default)
                .weight(text.weight.flatMap { Self.weights[$0] } ?? .regular))
            .foregroundStyle(text.colour?.color ?? Theme.text)
            .lineLimit(text.lines)
            .privacySensitive(context.privateText)
            .accessibilityIdentifier("widget-text-\(path)")
    }

    private func words(_ text: WidgetNode.Text) -> Text {
        guard let date = text.date else { return Text(verbatim: text.text) }
        let drawn = Text(date, style: Self.dateStyles[text.dateStyle] ?? .relative)
        return text.text.isEmpty ? drawn : Text(verbatim: text.text + " ") + drawn
    }

    static let styles: [WidgetNode.Text.Style: Font.TextStyle] = [
        .largeTitle: .largeTitle, .title: .title, .title2: .title2, .title3: .title3, .headline: .headline,
        .body: .body, .callout: .callout, .subheadline: .subheadline, .footnote: .footnote, .caption: .caption,
        .caption2: .caption2,
    ]
    static let weights: [WidgetNode.Text.Weight: Font.Weight] = [
        .ultraLight: .ultraLight, .thin: .thin, .light: .light, .regular: .regular, .medium: .medium,
        .semibold: .semibold, .bold: .bold, .heavy: .heavy, .black: .black,
    ]
    static let designs: [WidgetNode.Text.Design: Font.Design] = [
        .default: .default, .rounded: .rounded, .monospaced: .monospaced, .serif: .serif,
    ]
    static let dateStyles: [WidgetNode.Text.DateStyle: Text.DateStyle] = [
        .relative: .relative, .timer: .timer, .time: .time, .date: .date,
    ]

    private func glyphView(_ glyph: WidgetNode.Glyph) -> some View {
        Image(systemName: glyph.symbol)
            .font(.system(size: glyph.size))
            .foregroundStyle(glyph.colour?.color ?? Theme.text)
            .accessibilityIdentifier("widget-glyph-\(path)")
    }

    @ViewBuilder
    private func imageView(_ image: WidgetNode.Image) -> some View {
        if let data = context.images[image.name], let picture = UIImage(data: data) {
            Image(uiImage: picture)
                .resizable()
                .aspectRatio(contentMode: image.fit == .fill ? .fill : .fit)
                .frame(minWidth: 0, minHeight: 0)
                .clipShape(RoundedRectangle(cornerRadius: image.corner))
                .layoutPriority(-1)
        } else {
            // The slot has no image by that name: a mark where it would be, rather than nothing.
            Image(systemName: "photo").foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder
    private func gaugeView(_ gauge: WidgetNode.Gauge) -> some View {
        let tint = gauge.colour?.color ?? Theme.highlight
        let base = Gauge(value: gauge.value, in: gauge.min...gauge.max) {
            Text(verbatim: gauge.label ?? "")
        } currentValueLabel: {
            Text(verbatim: Self.number(gauge.value))
        }
        switch gauge.style {
        case .linear: base.gaugeStyle(.linearCapacity).tint(tint)
        case .circular: base.gaugeStyle(.accessoryCircular).tint(tint).scaledToFit().layoutPriority(-1)
        case .circularCapacity: base.gaugeStyle(.accessoryCircularCapacity).tint(tint).scaledToFit().layoutPriority(-1)
        }
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: Controls

    private func label(_ control: WidgetControl) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(control.label.enumerated()), id: \.offset) { index, node in
                WidgetNodeView(node: node, context: context, path: "\(path).label.\(index)")
            }
        }
    }

    @ViewBuilder
    private func controlView(_ control: WidgetControl) -> some View {
        Group {
            switch (control.kind, control.action) {
            case (_, .open):
                Link(destination: WidgetURL.open) { label(control) }
            case (.link, .turn(let say)):
                Link(destination: WidgetURL.cue(slot: context.slot, control: control.id, revision: context.revision, say: say)) {
                    label(control)
                }
            case (.toggle, .turn(let say)):
                Toggle(isOn: control.on, intent: WidgetCueIntent(slot: context.slot, control: control.id, revision: context.revision,
                                                                say: say, turningOn: !control.on)) { label(control) }
                    .toggleStyle(WidgetSwitch())
            case (.toggle, .run):
                Toggle(isOn: control.on, intent: WidgetRunIntent(slot: context.slot, control: control.id, revision: context.revision,
                                                                turningOn: !control.on)) { label(control) }
                    .toggleStyle(WidgetSwitch())
            case (_, .turn(let say)):
                Button(intent: WidgetCueIntent(slot: context.slot, control: control.id, revision: context.revision, say: say)) {
                    label(control)
                }
            case (_, .run):
                Button(intent: WidgetRunIntent(slot: context.slot, control: control.id, revision: context.revision)) {
                    label(control)
                }
            }
        }
        .tint(Theme.primary)
        .accessibilityIdentifier("widget-control-\(control.id)")
    }
}

/// A toggle drawn in shapes: the system's switch is UIKit's, which draws on a widget and nowhere
/// a test can render it. The state drawn is the document's `on`; the tap is the intent's.
struct WidgetSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Theme.primary : Theme.border)
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Theme.onPrimary).padding(2)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Topo himself, one still frame of the pose, drawn by the engine the chat draws him with.
struct WidgetMascotView: View {
    let pose: WidgetNode.Pose

    var body: some View {
        if let image = Self.still(pose) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Topo")
        } else {
            OctopusMark()
        }
    }

    /// The engine run long enough for the pose to settle, with its dice fixed so the same pose is
    /// the same picture every time it is drawn.
    static func still(_ pose: WidgetNode.Pose) -> CGImage? {
        #if canImport(TopoMascot)
        let engine = Topo(random: { 0.5 })
        for _ in 0..<60 { engine.update(1.0 / 30, TopoInput(activity: pose.rawValue)) }
        var rgba = [UInt8](repeating: 0, count: Topo.width * Topo.height * 4)
        engine.draw(&rgba)
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: Topo.width, height: Topo.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Topo.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        #else
        return nil
        #endif
    }
}
#endif

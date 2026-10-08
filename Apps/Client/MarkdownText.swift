import ImageIO
import SwiftUI
import TopoCore

/// Topo's words drawn as their blocks (`Markdown.blocks`): paragraphs and headings as text, list
/// items behind their markers, rules, fenced code in an enclosure of its own, a table as a grid,
/// an image read from the guest's home, and whatever sits inside a quote behind a bar for each
/// quote it is inside. Every value is the look's
/// (`Look.Markdown`), and a paragraph is drawn in the transcript's own type and ink, as the
/// transcript draws words.
///
/// `bare` is whether the turn draws nothing round its words. Then what Topo stands clear of is
/// the words themselves: each text reports its own lines (`mascotLines`), and what draws a shape
/// of its own — a code block's enclosure, a table's grid, a quote's bar, a rule — reports its frame
/// (`mascotObstacle`). An enclosed turn reports its enclosure from `TurnRow` and nothing here.
struct MarkdownText: View {
    let source: String
    var bare = true
    /// The turn these words are, which names each code block's place in the transcript
    /// (`CodeBlockCue.Place`) so the transcript can scroll to it. Nil draws the same words with no
    /// place to be scrolled to.
    var reply: TurnRef?
    /// The code block of these words the voice has reached, if any: its enclosure pulses, and it
    /// is what Topo stands beside.
    var cue: CodeBlockCue?
    @Environment(\.look) private var look
    @Environment(\.codeBlockAppeared) private var appeared

    var body: some View {
        VStack(alignment: .leading, spacing: look.markdown.blockSpacing) {
            ForEach(Array(Markdown.cached(source).enumerated()), id: \.offset) { _, block in
                quoted(block)
                    .padding(.leading, leadOutside(block))
            }
        }
    }

    /// A block behind a bar for each quote it sits inside, the bars as tall as what they enclose.
    /// The lists outside the quote have led the bars in already; the lists inside it lead only
    /// what the bars enclose, so every bar of one quote stands in one column however deeply what
    /// is inside it is nested.
    @ViewBuilder
    private func quoted(_ block: Markdown.Block) -> some View {
        if block.quote > 0 {
            HStack(alignment: .top, spacing: look.markdown.quoteIndent) {
                ForEach(0..<block.quote, id: \.self) { _ in
                    Rectangle()
                        .fill(look.markdown.quoteBar)
                        .frame(width: look.markdown.quoteBarWidth)
                        .mascotObstacle(bare)
                }
                row(block)
                    .padding(.leading, leadInside(block))
            }
            // The bars are as tall as the words beside them.
            .fixedSize(horizontal: false, vertical: true)
        } else {
            row(block)
        }
    }

    /// How far a block is led in before its bars: by the lists it sits inside that are outside
    /// its outermost quote. A block with no quote has every list outside it, so this is the whole
    /// of its lead and is what it was before there were bars.
    private func leadOutside(_ block: Markdown.Block) -> CGFloat {
        lead(block, lists: block.listsOutside, holdsTheMarker: inside(block) == 0)
    }

    /// How far what the bars enclose is led in: by the lists the block sits inside the quote.
    private func leadInside(_ block: Markdown.Block) -> CGFloat {
        lead(block, lists: inside(block), holdsTheMarker: true)
    }

    /// How many lists the block sits inside its outermost quote.
    private func inside(_ block: Markdown.Block) -> Int { block.depth - block.listsOutside }

    /// `lists` indents, less the one a list item's own marker is drawn for, so the marker sits
    /// where its list starts and anything else inside the item sits one indent in from it. The
    /// innermost list is the one the marker belongs to, so only the side holding it discounts one.
    private func lead(_ block: Markdown.Block, lists: Int, holdsTheMarker: Bool) -> CGFloat {
        var lists = lists
        if case .item = block.kind, holdsTheMarker { lists = max(lists - 1, 0) }
        return CGFloat(lists) * look.markdown.listIndent
    }

    @ViewBuilder
    private func row(_ block: Markdown.Block) -> some View {
        switch block.kind {
        case .paragraph:
            words(block.text, font: look.transcript.bodyFont, ink: ink(block))
        case .heading(let level):
            words(block.text, font: look.markdown.headingFont(level), ink: ink(block))
                .accessibilityAddTraits(.isHeader)
        case .item(let marker):
            HStack(alignment: .firstTextBaseline, spacing: look.markdown.markerSpacing) {
                Text(Self.marker(marker))
                    .font(look.transcript.bodyFont)
                    .foregroundStyle(look.markdown.marker)
                    .mascotLines(bare)
                words(block.text, font: look.transcript.bodyFont, ink: ink(block))
            }
        case .code:
            code(String(block.text.characters), number: block.codeNumber)
        case .table(let header, let rows):
            table(header: header, rows: rows, ink: ink(block))
        case .image(let source, let alt):
            ReplyImage(source: source, alt: alt, bare: bare)
        case .rule:
            Rectangle()
                .fill(look.markdown.marker)
                .frame(height: look.markdown.ruleWidth)
                .frame(maxWidth: .infinity)
                .mascotObstacle(bare)
        }
    }

    /// A block's words: the transcript's own ink, or a quote's whatever block it is, since words
    /// inside a quote are a quote's words. A fence keeps the look's code ink, being code still.
    private func ink(_ block: Markdown.Block) -> Color {
        block.quote > 0 ? look.markdown.quoteText : look.transcript.text
    }

    /// Words of a block, with inline code in the look's code type and ink and every other
    /// inline style — emphasis, strong, strikethrough — as `Text` draws it.
    private func words(_ text: AttributedString, font: Font, ink: Color) -> some View {
        Text(Self.styled(text, look: look.markdown))
            .font(font)
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
            .mascotLines(bare)
    }

    /// A fenced block in its own enclosure, scrolled sideways or wrapped as the look says, under
    /// its number in the reply at its trailing edge, in the type and ink of a turn's time. The
    /// number is what the voice says in the block's place ("See code block 2."), so a listener
    /// can find the block it means.
    ///
    /// When the voice reaches the block (`cue`), its enclosure pulses (`CodeBlockPulse`) and
    /// reports itself as the frame Topo stands beside (`mascotBeside`).
    private func code(_ text: String, number: Int?) -> some View {
        let reached = number != nil && cue?.number == number ? cue : nil
        return VStack(alignment: .trailing, spacing: look.transcript.captionSpacing) {
            if let number {
                Text("\(number)")
                    .font(look.transcript.labelFont)
                    .foregroundStyle(look.transcript.caption)
                    .mascotLines(bare)
                    .accessibilityLabel("Code block \(number)")
            }
            enclosed(text)
                .modifier(CodeBlockPulse(enclosure: look.markdown.codeBlock, pulse: look.markdown.codePulse,
                                         trigger: reached?.serial, still: reached?.still))
                .mascotBeside(reached?.serial)
        }
        .id(CodeBlockCue.Place(reply: reply, number: number))
        .onAppear { appeared(CodeBlockCue.Place(reply: reply, number: number)) }
    }

    /// The block's enclosure. It is drawn, so it is what Topo stands clear of, whole.
    @ViewBuilder
    private func enclosed(_ text: String) -> some View {
        let words = Text(text)
            .font(look.markdown.codeFont.monospaced())
            .foregroundStyle(look.markdown.codeInk)
        let enclosure = look.markdown.codeBlock
        Group {
            switch look.markdown.codeOverflow {
            case .scroll:
                ScrollView(.horizontal) {
                    words
                        .fixedSize()
                        .padding(.horizontal, enclosure.horizontalPadding)
                        .padding(.vertical, enclosure.verticalPadding)
                }
                .scrollIndicators(.hidden)
            case .wrap:
                words
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, enclosure.horizontalPadding)
                    .padding(.vertical, enclosure.verticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background { TurnShape.fill(enclosure) }
        .clipShape(RoundedRectangle(cornerRadius: enclosure.cornerRadius, style: .continuous))
        .mascotObstacle(bare)
    }

    /// A table as a grid: the header row in its own type over a rule, then the rows, every cell
    /// in its column and aligned as the column is. Where the look scrolls what overflows
    /// (`codeOverflow`), the grid is as wide as its cells and scrolls sideways, each cell no
    /// wider than `tableCellMaxWidth`; where it wraps, the grid is the column's width and its
    /// cells wrap inside it.
    @ViewBuilder
    private func table(header: Markdown.TableRow, rows: [Markdown.TableRow], ink: Color) -> some View {
        let scrolls = look.markdown.codeOverflow == .scroll
        let grid = Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: look.markdown.tableColumnSpacing,
                        verticalSpacing: look.markdown.tableRowSpacing) {
            GridRow {
                ForEach(Array(header.cells.enumerated()), id: \.offset) { _, cell in
                    self.cell(cell, font: look.markdown.tableHeaderFont, ink: ink, capped: scrolls)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Rectangle()
                .fill(look.markdown.tableRule)
                .frame(height: look.markdown.tableRuleWidth)
                .gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        self.cell(cell, font: look.transcript.bodyFont, ink: ink, capped: scrolls)
                    }
                }
            }
        }
        Group {
            if scrolls {
                ScrollView(.horizontal) { grid }
                    .scrollIndicators(.hidden)
            } else {
                grid.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .mascotObstacle(bare)
    }

    /// One cell's words, styled as a paragraph's are, on its column's side of the column.
    private func cell(_ cell: Markdown.TableCell, font: Font, ink: Color, capped: Bool) -> some View {
        Text(Self.styled(cell.text, look: look.markdown))
            .font(font)
            .foregroundStyle(ink)
            .multilineTextAlignment(Self.text(cell.alignment))
            .fixedSize(horizontal: false, vertical: true)
            .modifier(Capped(width: capped ? look.markdown.tableCellMaxWidth : nil))
            .gridColumnAlignment(Self.horizontal(cell.alignment))
    }

    private static func text(_ alignment: Markdown.ColumnAlignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private static func horizontal(_ alignment: Markdown.ColumnAlignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    static func marker(_ marker: Markdown.Marker) -> String {
        switch marker {
        case .bullet: "•"
        case .number(let n): "\(n)."
        }
    }

    /// `text` with its inline code runs in the look's code type, monospaced, and its code ink,
    /// and its linked runs underlined in the look's link ink. A linked run is the one part of a
    /// reply that is a tap target: `Text` makes exactly the run's own glyphs one, and opens its
    /// address through the environment's `openURL`.
    static func styled(_ text: AttributedString, look: Look.Markdown) -> AttributedString {
        var text = text
        let links = text.runs[\.link].compactMap { link, range in link == nil ? nil : range }
        for range in links {
            text[range].swiftUI.foregroundColor = look.linkInk
            text[range].swiftUI.underlineStyle = .single
        }
        let code = text.runs[\.inlinePresentationIntent].compactMap { intent, range in
            intent?.contains(.code) == true ? range : nil
        }
        for range in code {
            text[range].swiftUI.font = look.codeFont.monospaced()
        }
        // Code inside a link is the link's colour: its ink is what says it is one.
        for range in code where text[range].runs.allSatisfy({ $0.link == nil }) {
            text[range].swiftUI.foregroundColor = look.codeInk
        }
        return text
    }
}

/// A view offered no more than `width` across, whatever it is offered: inside a sideways scroll
/// nothing offers a width at all, and words offered none are one line as long as they are.
/// `nil` offers what was offered.
private struct Capped: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        if let width { Cap(width: width) { content } } else { content }
    }

    private struct Cap: Layout {
        let width: CGFloat

        private func offer(_ proposal: ProposedViewSize) -> ProposedViewSize {
            ProposedViewSize(width: min(proposal.width ?? width, width), height: proposal.height)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            subviews.first?.sizeThatFits(offer(proposal)) ?? .zero
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// An image in a reply. A source that is a path is read as the guest reads it, through the
/// reader the environment carries (`replyImages`): the guest's own path, absolute or from its
/// home, with its mounts and links, so a picture Claude Code could open is one the reply draws.
/// A web address is never fetched. A file that reads and decodes is drawn as wide as the
/// column, no taller than the look's `imageMaxHeight`, its corners cut to `imageCornerRadius`.
/// Anything else is drawn as the image's alternative text, in a quote's style, over why there
/// is no picture in the caption's ink — and, for a web address, the address as a link.
///
/// The read is the guest's and takes as long as it takes, so it is awaited off the main actor;
/// what the reader already holds of the source is drawn at once, in the row's first frame.
struct ReplyImage: View {
    let source: String
    let alt: String
    var bare = true
    @Environment(\.look) private var look
    @Environment(\.replyImages) private var images
    @State private var drawn: Drawn?

    /// What became of the source: a picture, or the reason there is none.
    enum Drawn: Equatable {
        case picture(CGImage)
        case missing(Missing)
    }

    enum Missing: Equatable {
        /// The guest has no such file that can be read as a picture: it was written on another
        /// device, there is no guest here, it is too large, or its bytes are no image.
        case notHere
        case onTheWeb(URL)
        case neither

        var reason: String {
            switch self {
            case .notHere: "Not on this device"
            case .onTheWeb: "On the web, so not fetched"
            case .neither: "Not a file or a web address"
            }
        }
    }

    /// The long side, in pixels, an image is decoded at: more than any column draws.
    static let pixels = 2048

    /// What `source` is drawn as before anything is read: a picture the reader already holds,
    /// the reason there will be none, or nil for a file still to be asked for.
    static func settled(_ source: String, kept: (String) -> Data?) -> Drawn? {
        switch Markdown.place(ofImage: source) {
        case .file(let path): kept(path).map { decoded($0).map(Drawn.picture) ?? .missing(.notHere) }
        case .web(let url): .missing(.onTheWeb(url))
        case .neither: .missing(.neither)
        }
    }

    /// What `source` is drawn as. The reader is asked only for a path, and nothing is fetched.
    static func resolve(_ source: String, read: (String) async -> Data?) async -> Drawn {
        switch Markdown.place(ofImage: source) {
        case .file(let path):
            guard let data = await read(path), let image = decoded(data) else { return .missing(.notHere) }
            return .picture(image)
        case .web(let url): return .missing(.onTheWeb(url))
        case .neither: return .missing(.neither)
        }
    }

    /// The picture in `data`, kept by the bytes it was decoded from: a lazy transcript makes a
    /// reply's row again each time it scrolls into view, and a decode is tens of milliseconds a
    /// picture. The file is still read each time, so a picture rewritten under the same name,
    /// or gone, is drawn as it now is.
    private static func decoded(_ data: Data) -> CGImage? {
        let key = data as NSData
        if let kept = cache.object(forKey: key) { return kept.image }
        guard let image = decode(data) else { return nil }
        cache.setObject(Kept(image), forKey: key, cost: data.count)
        return image
    }

    /// The picture in `data`, upright and no larger than `pixels` on its long side, or nil for
    /// bytes that are no image.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels,
                                        kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    var body: some View {
        Group {
            switch drawn {
            case .picture(let image):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: look.markdown.imageCornerRadius, style: .continuous))
                    .frame(maxHeight: look.markdown.imageMaxHeight, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement()
                    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                    .accessibilityAddTraits(.isImage)
            case .missing(let missing):
                fallback(missing)
            case nil:
                // Not yet read: the room a line takes, so the reply does not jump far.
                Text(alt).font(look.transcript.bodyFont).hidden()
            }
        }
        .mascotObstacle(bare)
        .onAppear { if drawn == nil { drawn = Self.settled(source, kept: images.kept) } }
        // Read again when the source changes and when what the guest can read does: a row
        // drawn before the guest has its home has no picture yet, and gets it then.
        .task(id: Asked(source: source, epoch: images.epoch)) {
            let read = images.read
            let resolved = await Self.resolve(source, read: read)
            if !Task.isCancelled { drawn = resolved }
        }
    }

    private struct Asked: Hashable {
        var source: String
        var epoch: Int
    }

    /// The alternative text behind a quote's bar, over the reason.
    private func fallback(_ missing: Missing) -> some View {
        HStack(alignment: .top, spacing: look.markdown.quoteIndent) {
            Rectangle()
                .fill(look.markdown.quoteBar)
                .frame(width: look.markdown.quoteBarWidth)
            VStack(alignment: .leading, spacing: look.transcript.captionSpacing) {
                if !alt.isEmpty {
                    Text(alt)
                        .font(look.transcript.bodyFont)
                        .foregroundStyle(look.markdown.quoteText)
                }
                Text(missing.reason)
                    .font(look.transcript.labelFont)
                    .foregroundStyle(look.transcript.caption)
                if case .onTheWeb(let url) = missing {
                    Text(MarkdownText.styled(Self.link(url), look: look.markdown))
                        .font(look.transcript.labelFont)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A web address as words that are a link to it.
    static func link(_ url: URL) -> AttributedString {
        var text = AttributedString(url.absoluteString)
        text.link = url
        return text
    }

    private final class Kept: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSData, Kept> = {
        let cache = NSCache<NSData, Kept>()
        cache.countLimit = 16
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
}

/// How a reply's images are read: by the guest's own path.
struct ReplyImages: Sendable {
    /// What is already in hand for a path, with no waiting: what a row is drawn with in its
    /// first frame.
    var kept: @Sendable (String) -> Data? = { _ in nil }
    /// The file's bytes as the guest reads them now, or nil.
    var read: @Sendable (String) async -> Data? = { _ in nil }
    /// Counts the changes in what the guest can read — its home mounted, the memory mounted,
    /// a sign-out; a row reads again when this changes.
    var epoch = 0
}

private struct ReplyImagesKey: EnvironmentKey {
    static let defaultValue = ReplyImages()
}

extension EnvironmentValues {
    /// Reads an image a reply names by its path in the guest. The app hands down the guest's
    /// reader (`GuestImages`); everywhere else — a watch, a television, a preview — there is
    /// no guest and so no picture.
    var replyImages: ReplyImages {
        get { self[ReplyImagesKey.self] }
        set { self[ReplyImagesKey.self] = newValue }
    }
}

private struct CodeBlockAppearedKey: EnvironmentKey {
    static let defaultValue: @MainActor (CodeBlockCue.Place) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Told each code block's place as the block is made, which the transcript scrolls to once a
    /// row it asked for has been made (`TranscriptView`).
    var codeBlockAppeared: @MainActor (CodeBlockCue.Place) -> Void {
        get { self[CodeBlockAppearedKey.self] }
        set { self[CodeBlockAppearedKey.self] = newValue }
    }
}

/// The voice has reached a code block of a reply: the sentence that stands for it ("See code block
/// N.", `Speakable.line(forCodeBlock:)`) has begun. The transcript scrolls the block into view, its
/// enclosure pulses and Topo goes to stand on the other side of the transcript from it. Only a
/// reply being read aloud makes one (`Speaker.cue`), so a block that is only in the transcript is
/// never reached.
struct CodeBlockCue: Equatable, Sendable {
    /// The reply being read.
    var reply: TurnRef
    /// The block's number in the reply, as its caption draws it.
    var number: Int
    /// Counts cues, so the same block reached twice — the reply said again — is a new one.
    var serial: Int
    /// A moment of the pulse, in seconds from its start, drawn still and not animated: a
    /// preview's or a render's. Nil is the pulse as it plays.
    var still: Double?

    /// Where a code block is in the transcript, which it is scrolled to by.
    struct Place: Hashable {
        var reply: TurnRef?
        var number: Int?
    }

    var place: Place { Place(reply: reply, number: number) }
}

/// A code block's outline breathing when the voice reaches it: from nothing to the look's width
/// and opacity in its accent and back, `Look.Markdown.Pulse.cycles` times, eased all the way
/// (`Pulse.level`), over the enclosure's own shape. It plays each time `trigger` changes to a
/// new serial — not when it goes back to nil — or appears with a serial it has not played, and
/// draws nothing at rest; with `still` it draws that moment of the pulse and plays nothing.
struct CodeBlockPulse: ViewModifier {
    let enclosure: Look.Enclosure
    let pulse: Look.Markdown.Pulse
    let trigger: Int?
    var still: Double?
    /// The last cue this block played. The animator plays on every change of its trigger, and the
    /// voice moving on to another block turns this one's `trigger` back to nil, which is not a
    /// cue of this block: only a new serial is.
    @State private var played: Int?

    @ViewBuilder
    func body(content: Content) -> some View {
        let enclosure = enclosure, pulse = pulse
        if let still {
            content.overlay { Self.outline(pulse.level(at: still), enclosure: enclosure, pulse: pulse) }
        } else {
            content.keyframeAnimator(initialValue: pulse.duration, trigger: played) { content, time in
                content.overlay { Self.outline(pulse.level(at: time), enclosure: enclosure, pulse: pulse) }
            } keyframes: { _ in
                // The clock of the pulse, run from its start to its end; what it draws at each
                // moment is `level`, so the ease is the pulse's own and not the keyframe's.
                KeyframeTrack(\.self) {
                    MoveKeyframe(0)
                    LinearKeyframe(pulse.duration, duration: pulse.duration)
                }
            }
            .onChange(of: trigger) { _, cue in
                if let cue { played = cue }
            }
            // A block first drawn with its cue already set — a row the lazy transcript makes as
            // it scrolls to the block — has no change to see, so it plays as it appears: on the
            // pass after, since a change in the pass that makes the animator is not one it plays.
            .onAppear {
                guard let trigger, played != trigger else { return }
                DispatchQueue.main.async { played = trigger }
            }
        }
    }

    /// The outline at `level`, 0 at rest and 1 at the peak: its width and its opacity both
    /// that share of the look's, drawn inside the enclosure's edge so it covers nothing beside it.
    private nonisolated static func outline(_ level: Double, enclosure: Look.Enclosure,
                                            pulse: Look.Markdown.Pulse) -> some View {
        RoundedRectangle(cornerRadius: enclosure.cornerRadius, style: .continuous)
            .strokeBorder(pulse.accent.opacity(pulse.opacity * level), lineWidth: pulse.width * level)
            .allowsHitTesting(false)
    }
}

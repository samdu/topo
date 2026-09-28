#if DEBUG
import SwiftUI

/// A debug build's host for one widget document, drawn by `WidgetNodeView` in the app rather than
/// on the home screen, where a UI test can find each text and control by its identifier and tap
/// it: `TOPO_DEBUG_WIDGET=<the document's JSON>` launches the app into it, drawing the document's
/// first family at that family's size.
///
/// Each tap goes through the control's own intent or URL, and what reached the app is shown in
/// `widget-handed`: `cue: <words>` for a turn, `run: <argv>` for a run, `url: <url>` for a link.
/// Nothing is sent and nothing runs: the host stands in for the app's handler.
struct WidgetHostView: View {
    static let variable = "TOPO_DEBUG_WIDGET"
    static let handedIdentifier = "widget-handed"

    /// The document a launch asked for, or nil when it asked for none.
    @MainActor static let launched: WidgetDocument? = ProcessInfo.processInfo.environment[variable]
        .map { WidgetDocument.read($0).document }

    let document: WidgetDocument
    @State private var recorder = WidgetHostRecorder()

    static let sizes: [WidgetFamilyName: CGSize] = [
        .systemSmall: CGSize(width: 170, height: 170), .systemMedium: CGSize(width: 364, height: 170),
        .systemLarge: CGSize(width: 364, height: 382), .accessoryCircular: CGSize(width: 76, height: 76),
        .accessoryRectangular: CGSize(width: 172, height: 76), .accessoryInline: CGSize(width: 257, height: 26),
    ]

    var body: some View {
        let family = WidgetFamilyName.allCases.first { document.families[$0] != nil } ?? .default
        VStack(spacing: 24) {
            if let node = document.tree(for: family) {
                WidgetNodeView(node: node, context: WidgetContext(slot: "fixture", revision: document.revision, family: family))
                    .padding(family.isAccessory ? 0 : 16)
                    .frame(width: Self.sizes[family]?.width, height: Self.sizes[family]?.height)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
            }
            Text(verbatim: recorder.handed.last ?? "nothing yet")
                .font(.footnote.monospaced())
                .accessibilityIdentifier(Self.handedIdentifier)
                .accessibilityValue(recorder.handed.joined(separator: "\n"))
        }
        .onAppear {
            recorder.document = document
            WidgetIntents.handler = recorder
        }
        .onOpenURL { url in recorder.handed.append("url: \(url.absoluteString)") }
    }
}

/// The host's stand-in for the app's tap handler: it writes down what each tap handed on.
@MainActor
@Observable
final class WidgetHostRecorder: WidgetTapHandler {
    var handed: [String] = []
    var document = WidgetDocument()

    func cued(_ cue: SurfaceStore.Cue, recorded: Bool) async {
        // What the intent put in the app group is taken back out, so a later ordinary launch on
        // this simulator does not send it.
        if recorded { try? SurfaceStore.shared()?.removeCue(nonce: cue.nonce) }
        handed.append("cue: \(cue.words)")
    }

    func run(slot: String, control: String, revision: Int, turningOn: Bool?) async {
        let argv = document.controls[control]?.argv(turningOn: turningOn) ?? []
        handed.append("run: " + argv.joined(separator: " "))
    }
}
#endif

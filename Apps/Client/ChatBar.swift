#if os(iOS)
import SwiftUI

/// The two controls at the leading edge of the chat's navigation bar: the model, a menu of what
/// the chat offers under the look's names, and the mute. They are the bar's and not the glass's,
/// so they are drawn plainly in `Look.Bar` and are there whatever the pane under the transcript
/// is doing. The menu is the system's, so a model is chosen as anything else in a bar is.
struct ChatBar: View {
    /// A model the chat offers: its alias, which is what `choose` is handed, and what the look
    /// calls it.
    struct Model: Equatable, Identifiable, Sendable {
        var id: String
        var name: String
    }

    /// Smallest first.
    var models: [Model]
    /// The alias of the one chosen.
    var chosen: String
    var choose: (String) -> Void = { _ in }
    /// Replies to spoken turns are read aloud. The mute says so and asks for the other; what
    /// muting ends is the chat's.
    var readsAloud = true
    var setReadsAloud: (Bool) -> Void = { _ in }
    @Environment(\.look) private var look

    /// What the UI suites find the two controls by.
    static let model = "chat-model"
    static let mute = "chat-mute"

    var body: some View {
        let flank = look.composer.flank
        HStack(spacing: look.bar.spacing) {
            Menu {
                Picker("Model", selection: Binding(get: { chosen }, set: choose)) {
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
            } label: {
                Image(systemName: flank.models)
            }
            .accessibilityIdentifier(Self.model)
            .accessibilityLabel("Model")
            .accessibilityValue(models.first { $0.id == chosen }?.name ?? "")
            Button { setReadsAloud(!readsAloud) } label: {
                // Both marks are laid out and one is drawn, so the control is one size either way.
                ZStack {
                    Image(systemName: flank.speaking).opacity(readsAloud ? 1 : 0)
                    Image(systemName: flank.muted).opacity(readsAloud ? 0 : 1)
                }
            }
            .accessibilityIdentifier(Self.mute)
            .accessibilityLabel(readsAloud ? "Mute replies" : "Read replies aloud")
        }
        .font(look.bar.font)
        // The bar is a fixed height, so its controls stop growing with the text setting where
        // its notice does.
        .dynamicTypeSize(...ChatNotices.largestType)
        .tint(look.bar.ink)
        .foregroundStyle(look.bar.ink)
    }
}
#endif

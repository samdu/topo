import ReplayKit
import SwiftUI

/// The settings row a screen share is started from: the system's own broadcast button, set to
/// Topo's extension, which puts up the system's sheet. The person presses it and the sheet's
/// Start themselves; nothing in the app presses either for them.
struct ScreenShareSection: View {
    @Environment(\.look) private var look

    var body: some View {
        Section {
            LabeledContent("Share the screen with Topo") {
                BroadcastButton(tint: look.settings.tint, side: look.settings.broadcastButton)
                    .frame(width: look.settings.broadcastButton, height: look.settings.broadcastButton)
                    .accessibilityIdentifier("settings-screen-share")
            }
        } footer: {
            Text("While you share it, Topo keeps stills of your screen on this phone to look at when you ask. You start it and stop it, and the stills go when you sign out or make another device Topo's.")
        }
    }
}

/// The sheet the composer's `+` puts up to share the screen from: the settings row and its
/// words, with the system's own button to press, and nothing of the app's that presses it.
struct ScreenShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { ScreenShareSection() }
                .navigationTitle("Share your screen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("screen-share-done")
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

/// `RPSystemBroadcastPickerView`, offering Topo's broadcast alone and no microphone.
struct BroadcastButton: UIViewRepresentable {
    var tint: Color
    var side: CGFloat

    static let broadcast = "zone.hexagon.topo.broadcast"

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        // The picker sizes its button from the frame it is made with and stretches it from there;
        // made with none, the button has no size at any later frame and no press reaches it.
        let picker = RPSystemBroadcastPickerView(frame: CGRect(origin: .zero, size: CGSize(width: side, height: side)))
        picker.preferredExtension = Self.broadcast
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        // The system draws its mark white, which a settings row does not show.
        for case let button as UIButton in picker.subviews {
            button.imageView?.tintColor = UIColor(tint)
        }
    }
}

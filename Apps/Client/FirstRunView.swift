#if os(iOS) || os(macOS)
import SwiftUI
#if canImport(AVFAudio)
import AVFAudio
#endif

/// The first ten minutes: one question, with the microphone the only permission asked, at the
/// first press. The answer is kept in `firstRunAnswer` until the turn log takes it as the first
/// turn; nothing said here is dropped.
struct FirstRunView: View {
    @AppStorage("firstRunAnswer") private var storedAnswer = ""
    @State private var answer = ""
    @State private var micDenied = false
    @State private var listening = false
    var onDone: (String) -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("What did you forget this week?")
                .font(.system(.title, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
            Text("or just start talking")
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await pressMic() }
            } label: {
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(.system(size: 36))
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(Theme.teal))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            if micDenied {
                Text("Topo can't hear you without the microphone. You can type instead, or allow it in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack {
                TextField("Type it instead", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Go", action: submit)
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(maxWidth: 360)
            Spacer().frame(height: 24)
        }
        .padding()
    }

    private func submit() {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        storedAnswer = text
        onDone(text)
    }

    /// The microphone is asked for here and nowhere earlier.
    private func pressMic() async {
        #if os(iOS) || os(watchOS)
        let granted = await AVAudioApplication.requestRecordPermission()
        micDenied = !granted
        listening = granted
        #else
        micDenied = true
        #endif
    }
}
#endif

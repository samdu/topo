#if os(iOS) || os(macOS)
import SwiftUI

/// The first ten minutes: one question, with the microphone and speech recognition asked for at
/// the first press and nothing before it. The answer is kept in `firstRunAnswer` until the turn
/// log takes it as the first turn; nothing said here is dropped.
struct FirstRunView: View {
    @AppStorage("firstRunAnswer") private var storedAnswer = ""
    @State private var answer = ""
    #if os(iOS)
    @Environment(VoiceInput.self) private var voice
    #endif
    var onDone: (String) -> Void

    private var micDenied: Bool {
        #if os(iOS)
        voice.denied
        #else
        true
        #endif
    }

    private var listening: Bool {
        #if os(iOS)
        voice.listening && voice.owner == .firstRun
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("What did you forget this week?")
                .font(.system(.title, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
            Text("or just start talking")
                .foregroundStyle(.secondary)
            Spacer()
            // Hold to talk, release to answer. The two permissions are asked here and nowhere earlier.
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.system(size: 36))
                .frame(width: 96, height: 96)
                .background(Circle().fill(Theme.teal))
                .foregroundStyle(.white)
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 60) {} onPressingChanged: { down in
                    Task { await pressed(down) }
                }
            if listening, !answer.isEmpty {
                Text(answer).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
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
        #if os(iOS)
        .onDisappear { voice.cancel(.firstRun) }
        #endif
    }

    private func submit() {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        storedAnswer = text
        onDone(text)
    }

    /// Hold to talk, release to answer; on this screen a tap is a short hold, not a hands-free
    /// press, since one answer is all it takes.
    private func pressed(_ down: Bool) async {
        #if os(iOS)
        let heard = down ? await voice.pressDown(as: .firstRun) : await voice.pressUp(as: .firstRun)
        if let heard {
            answer = heard
            submit()
        } else if !down, voice.handsFree {
            answer = await voice.pressDown(as: .firstRun) ?? ""
            submit()
        }
        #endif
    }
}
#endif

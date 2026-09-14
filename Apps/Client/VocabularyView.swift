#if os(iOS)
import SwiftUI

/// The ear's word list, edited in place: a name it keeps mangling goes in here and works from
/// the next press. Opened from the chat menu.
struct VocabularyView: View {
    @Environment(VoiceInput.self) private var voice
    @Environment(\.dismiss) private var dismiss
    /// The field's draft, until Add spends it.
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(voice.ear.vocabulary.terms, id: \.self) { term in
                        Text(term).font(.system(.body, design: .monospaced))
                    }
                    .onDelete { voice.ear.vocabulary.remove(atOffsets: $0) }
                    HStack {
                        TextField("Add a word", text: $draft)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(!Vocabulary.accepts(draft))
                    }
                } footer: {
                    Text("Names and words the recogniser gets wrong, spelt the way you want them written. One applies from the next press; swipe to remove it. Spelling only, no sound-alikes: the matcher finds those itself. Kept on this device.")
                }
            }
            .navigationTitle("Vocabulary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func add() {
        if voice.ear.vocabulary.add(draft) { draft = "" }
    }
}
#endif

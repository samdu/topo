#if os(iOS)
import SwiftUI

/// Who to thank: the mark, the version, where the name comes from, and what
/// `THIRD-PARTY` says. The list is read from the file in the bundle rather
/// than written here, so a licence added to the file shows up on the screen
/// and nobody has to remember both.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    private let acknowledgements = Acknowledgements.bundled()
    private let licence = Licence.bundled()

    var body: some View {
        NavigationStack {
            List {
                Section { header.listRowSeparator(.hidden) }
                Section("The name") {
                    Text("Topo is Aquaman's octopus sidekick, first seen in Adventure Comics #229 (1956), written by Jack Miller and drawn by Ramona Fradon. The product is the octopus: the mind is the head and every device is an arm.")
                }
                Section("Licence") {
                    Text(licence.source).font(.footnote).textSelection(.enabled)
                    if let text = licence.text {
                        NavigationLink(Licence.name) {
                            ScrollView {
                                Text(text).font(.footnote.monospaced()).textSelection(.enabled).padding()
                            }
                            .navigationTitle("Licence")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                    } else {
                        Text("LICENSE is missing from this build.").foregroundStyle(.red)
                    }
                }
                if let acknowledgements {
                    Section("Acknowledgements") {
                        ForEach(acknowledgements.note, id: \.self) { paragraph in
                            Text(paragraph).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(acknowledgements.entries) { entry in
                        Section(entry.name) {
                            ForEach(entry.fields) { field in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.key).font(.caption).foregroundStyle(.secondary)
                                    Text(field.value).textSelection(.enabled)
                                }
                            }
                        }
                    }
                } else {
                    Section("Acknowledgements") {
                        Text("THIRD-PARTY is missing from this build.").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            OctopusMark().frame(width: 88, height: 88)
            Text("Topo").font(.title2.weight(.semibold))
            Text(Self.version).font(.footnote).foregroundStyle(.secondary)
            Text("Open source under the GPL, and not for profit.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.vertical, 8)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(marketing) (\(build))"
    }
}

/// The GPL's text, read out of the app's own bundle, and where the source this build was made
/// from can be had. The app links the iSH fork, which is GPL-3.0; its holders' App Store waiver
/// (quoted in `THIRD-PARTY`) stands as long as the app meets the GPL otherwise, which is its text
/// and its source offered to whoever has the app.
struct Licence: Equatable {
    static let name = "GNU General Public License, version 3"
    static let repository = "https://github.com/samdu/topo"

    /// The licence's text, or nil for a build that left the resource out.
    var text: String?
    /// The commit the build was made from, as `scripts/archive-upload.sh` writes it into the
    /// Info.plist; empty for a build made any other way.
    var commit: String

    /// Where the corresponding source is: this repository at the build's commit, and the fork,
    /// whose pin and patches `THIRD-PARTY` names.
    var source: String {
        let at = commit.isEmpty ? "at the commit this build was made from" : "at commit \(commit)"
        return "Topo is free software under the \(Self.name). Its source is \(Self.repository), \(at); the iSH fork's is at the pin THIRD-PARTY names, with the patches in the repository's patches/ish."
    }

    static func bundled(in bundle: Bundle = .main) -> Licence {
        let text = bundle.url(forResource: "LICENSE", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let commit = bundle.object(forInfoDictionaryKey: "TopoSourceCommit") as? String ?? ""
        return Licence(text: text, commit: commit.trimmingCharacters(in: .whitespaces))
    }
}
#endif

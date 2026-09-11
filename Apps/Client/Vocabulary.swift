#if os(iOS)
import Foundation
import Observation

/// The words the ear is rescored towards: the names and jargon this person's recogniser breaks
/// on. Empty until the person adds something, because Topo is one mind per person and no list
/// of anyone else's words is theirs.
///
/// Kept in this device's defaults. The CloudKit vault is where a list every limb shares would
/// live, but the client does not read the vault yet, so the list stays on the device that
/// listens: the only one that rescores anything.
///
/// The store is the list and its persistence; the ear registers for `changed` and rebuilds the
/// spotter's session on every edit, so an added word works from the next press.
@MainActor
@Observable
final class Vocabulary {
    static let key = "vocabulary"

    private(set) var terms: [String]
    private let defaults: UserDefaults
    /// Called after every edit, with the list already saved. The ear's.
    @ObservationIgnored var changed: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terms = defaults.stringArray(forKey: Self.key) ?? []
    }

    /// One word from the editor's field, trimmed. Under the rescorer's own length gate it would
    /// be ignored, and a spelling already present, in any case, is a no-op; both are refused.
    @discardableResult
    func add(_ term: String) -> Bool {
        let word = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.accepts(word), !contains(word) else { return false }
        terms.append(word)
        save()
        return true
    }

    func remove(atOffsets offsets: IndexSet) {
        terms.remove(atOffsets: offsets)
        save()
    }

    /// Whether the editor's field holds something `add` would take: the rescorer's
    /// `minTermLength`, so a word it would ignore is never saved.
    static func accepts(_ term: String) -> Bool {
        term.trimmingCharacters(in: .whitespacesAndNewlines).count >= Ear.minTermLength
    }

    private func contains(_ word: String) -> Bool {
        terms.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    private func save() {
        defaults.set(terms, forKey: Self.key)
        changed?()
    }
}
#endif

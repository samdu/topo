import Foundation

/// What an installer throws when a file is not its pin. Each installer's `Failure` is one: its
/// cases are these requirements.
protocol PinMismatch: Error {
    static func unreadable(_ why: String) -> Self
    static func wrongSize(expected: Int64, got: Int64) -> Self
    static var wrongDigest: Self { get }
}

/// A downloaded file checked against its pin: the size first, then the digest, so a file cut
/// short costs no hash.
enum PinnedFile {
    static func verify<Mismatch: PinMismatch>(_ url: URL, size: Int64, sha256: String, as _: Mismatch.Type,
                                              digest: (URL) throws -> String) throws {
        let found: Int64
        do {
            found = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        } catch {
            throw Mismatch.unreadable(error.localizedDescription)
        }
        guard found == size else { throw Mismatch.wrongSize(expected: size, got: found) }
        guard try digest(url) == sha256.lowercased() else { throw Mismatch.wrongDigest }
    }
}

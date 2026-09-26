import Foundation

/// A call as the guest's `topo` sends it: the service's token on the first line, then the
/// arguments, each one's UTF-8 in base64, one to a line, each line ended by a newline, so a space,
/// a quote, a `$`, a newline or an empty argument (an empty line) arrives as it was given. The
/// token rides in the body because a header would have to be given to `wget` as an argument, and
/// every process in the guest can read every other's arguments. Base64 rather than the bytes
/// themselves because BusyBox `wget --post-file` sends its file only up to the first NUL.
public enum ToolRequest {
    /// Why a body is not a call.
    public enum Refusal: Error, Equatable {
        case unterminated
        case notBase64
        case notUTF8
    }

    /// The token line, and the arguments after it; nil when the body has no first line.
    public static func split(_ body: Data) -> (token: String, arguments: Data)? {
        guard let end = body.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return (String(decoding: body[..<end], as: UTF8.self), Data(body[body.index(after: end)...]))
    }

    public static func arguments(from body: Data) throws -> [String] {
        guard !body.isEmpty else { return [] }
        guard body.last == UInt8(ascii: "\n") else { throw Refusal.unterminated }
        return try body.dropLast().split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { line in
            guard let bytes = Data(base64Encoded: Data(line)) else { throw Refusal.notBase64 }
            guard let text = String(data: bytes, encoding: .utf8) else { throw Refusal.notUTF8 }
            return text
        }
    }

    /// The body `topo` sends for `arguments`: what the suites send in its place.
    public static func body(token: String, _ arguments: [String]) -> Data {
        Data((token + "\n" + arguments.map { Data($0.utf8).base64EncodedString() + "\n" }.joined()).utf8)
    }
}

import Foundation

/// A call's arguments as the guest's `topo` sends them: each one's UTF-8 in base64, one to a line,
/// each line ended by a newline, so a space, a quote, a `$`, a newline or an empty argument (an
/// empty line) arrives as it was given. No argument at all is an empty body. Base64 rather than
/// the bytes themselves because BusyBox `wget --post-file` sends its file only up to the first NUL.
public enum ToolRequest {
    /// Why a body is not a call.
    public enum Refusal: Error, Equatable {
        case unterminated
        case notBase64
        case notUTF8
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
    public static func body(_ arguments: [String]) -> Data {
        Data(arguments.map { Data($0.utf8).base64EncodedString() + "\n" }.joined().utf8)
    }
}

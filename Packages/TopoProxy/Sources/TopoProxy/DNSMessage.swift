import Foundation

/// The little of RFC 1035 the forwarder speaks: a query's header, its one question and an EDNS
/// size read in, and a reply of that header, that question and whole resource records written out
/// (names uncompressed).
public struct DNSQuery: Equatable, Sendable {
    public static let typeCNAME: UInt16 = 5
    public static let typeOPT: UInt16 = 41
    public static let typeANY: UInt16 = 255
    public static let classIN: UInt16 = 1

    public let id: UInt16
    /// Whether the client asked for recursion; echoed.
    public let recursionDesired: Bool
    /// The question as the client wrote it: name, type and class, echoed in the reply.
    public let question: [UInt8]
    /// The question's name as labels.
    public let labels: [[UInt8]]
    public let type: UInt16
    public let qclass: UInt16
    /// The UDP size the client's OPT record offers, or nil when it sent none.
    public let ednsSize: UInt16?

    /// What reading a query can find, short of a question to ask.
    public enum Refusal: Error, Equatable {
        /// Not a query at all (a reply, or too short to carry a header): not answered.
        case unanswerable
        /// Answered with this code and no question: `FORMERR` (1) or `NOTIMP` (4).
        case reply(id: UInt16, rd: Bool, rcode: UInt8, question: [UInt8])
    }

    public static func read(_ bytes: [UInt8]) throws(Refusal) -> DNSQuery {
        guard bytes.count >= 12 else { throw .unanswerable }
        let id = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let flags = bytes[2]
        guard flags & 0x80 == 0 else { throw .unanswerable }
        let rd = flags & 0x01 != 0
        let opcode = (flags >> 3) & 0x0f
        let qdcount = Int(bytes[4]) << 8 | Int(bytes[5])
        let ancount = Int(bytes[6]) << 8 | Int(bytes[7])
        let nscount = Int(bytes[8]) << 8 | Int(bytes[9])
        let arcount = Int(bytes[10]) << 8 | Int(bytes[11])
        guard opcode == 0 else { throw .reply(id: id, rd: rd, rcode: 4, question: []) }
        guard qdcount == 1, ancount == 0, nscount == 0, arcount <= 1 else {
            throw .reply(id: id, rd: rd, rcode: 1, question: [])
        }
        var at = 12
        guard let labels = readName(bytes, &at), at + 4 <= bytes.count else {
            throw .reply(id: id, rd: rd, rcode: 1, question: [])
        }
        let type = UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
        let qclass = UInt16(bytes[at + 2]) << 8 | UInt16(bytes[at + 3])
        at += 4
        let question = Array(bytes[12..<at])
        var ednsSize: UInt16?
        if arcount == 1 {
            // Only an OPT at the root is read; anything else in the additional section is malformed.
            guard at + 11 <= bytes.count, bytes[at] == 0,
                  UInt16(bytes[at + 1]) << 8 | UInt16(bytes[at + 2]) == typeOPT else {
                throw .reply(id: id, rd: rd, rcode: 1, question: question)
            }
            ednsSize = UInt16(bytes[at + 3]) << 8 | UInt16(bytes[at + 4])
            let rdlength = Int(bytes[at + 9]) << 8 | Int(bytes[at + 10])
            at += 11 + rdlength
        }
        guard at == bytes.count else { throw .reply(id: id, rd: rd, rcode: 1, question: question) }
        // Zone transfers and classes other than IN are nothing the system resolver answers.
        guard qclass == classIN, type != 251, type != 252 else {
            throw .reply(id: id, rd: rd, rcode: 4, question: question)
        }
        return DNSQuery(id: id, recursionDesired: rd, question: question, labels: labels, type: type,
                        qclass: qclass, ednsSize: ednsSize)
    }

    /// A name of uncompressed labels, as a query carries it; nil for a pointer, an overlong name
    /// or one running past the message.
    private static func readName(_ bytes: [UInt8], _ at: inout Int) -> [[UInt8]]? {
        var labels = [[UInt8]]()
        var total = 1
        while at < bytes.count {
            let length = Int(bytes[at])
            at += 1
            if length == 0 { return labels }
            guard length < 64, at + length <= bytes.count else { return nil }
            total += length + 1
            guard total <= 255 else { return nil }
            labels.append(Array(bytes[at..<(at + length)]))
            at += length
        }
        return nil
    }

    /// The name in the text form dnssd takes: labels joined by dots, a dot or backslash inside a
    /// label escaped with a backslash, and any byte that is not printable ASCII as `\DDD`.
    public var presentationName: String {
        if labels.isEmpty { return "." }
        return labels.map { label in
            label.map { byte -> String in
                switch byte {
                case UInt8(ascii: "."), UInt8(ascii: "\\"): "\\" + String(UnicodeScalar(byte))
                case 0x21...0x7e: String(UnicodeScalar(byte))
                default: "\\" + String(format: "%03d", byte)
                }
            }.joined()
        }.joined(separator: ".") + "."
    }
}

/// One resource record of a reply.
public struct DNSRecord: Equatable, Sendable {
    public let labels: [[UInt8]]
    public let type: UInt16
    public let rclass: UInt16
    public let ttl: UInt32
    public let rdata: [UInt8]

    public init(labels: [[UInt8]], type: UInt16, rclass: UInt16 = DNSQuery.classIN, ttl: UInt32, rdata: [UInt8]) {
        self.labels = labels
        self.type = type
        self.rclass = rclass
        self.ttl = ttl
        self.rdata = rdata
    }

    /// Labels from the text form dnssd hands back (`\DDD` and `\X` escapes read), or nil for a
    /// name that does not make whole labels.
    public static func labels(presentation name: [UInt8]) -> [[UInt8]]? {
        var labels = [[UInt8]](), label = [UInt8]()
        var bytes = name[...]
        while let byte = bytes.popFirst() {
            if byte == UInt8(ascii: ".") {
                guard !label.isEmpty else { return bytes.isEmpty && labels.isEmpty ? [] : nil }
                labels.append(label)
                label = []
            } else if byte == UInt8(ascii: "\\") {
                guard let next = bytes.popFirst() else { return nil }
                if (0x30...0x39).contains(next) {
                    guard bytes.count >= 2, let rest = String(bytes: [next] + bytes.prefix(2), encoding: .ascii),
                          let value = UInt8(rest) else { return nil }
                    bytes = bytes.dropFirst(2)
                    label.append(value)
                } else {
                    label.append(next)
                }
            } else {
                label.append(byte)
            }
            guard label.count < 64 else { return nil }
        }
        if !label.isEmpty { labels.append(label) }
        return labels.reduce(1, { $0 + $1.count + 1 }) <= 255 ? labels : nil
    }

    var wire: [UInt8] {
        var out = DNSReply.name(labels)
        out += [UInt8(type >> 8), UInt8(type & 0xff), UInt8(rclass >> 8), UInt8(rclass & 0xff)]
        out += [UInt8(ttl >> 24), UInt8((ttl >> 16) & 0xff), UInt8((ttl >> 8) & 0xff), UInt8(ttl & 0xff)]
        out += [UInt8(rdata.count >> 8), UInt8(rdata.count & 0xff)] + rdata
        return out
    }
}

/// A reply's bytes.
public enum DNSReply {
    public static let noError: UInt8 = 0
    public static let formErr: UInt8 = 1
    public static let servFail: UInt8 = 2
    public static let nxDomain: UInt8 = 3
    public static let notImp: UInt8 = 4

    /// A reply to `query` with `rcode` and `answers`, kept to `limit` bytes: when the whole does
    /// not fit, it is the header and question alone with `TC` set, and `truncated` says so. An OPT
    /// record offering `ednsSize` goes in when the query carried one.
    public static func make(to query: DNSQuery, rcode: UInt8, answers: [DNSRecord], limit: Int,
                            ednsSize: UInt16) -> (bytes: [UInt8], truncated: Bool) {
        let opt: [UInt8] = query.ednsSize == nil ? [] : [0, 0, 41, UInt8(ednsSize >> 8), UInt8(ednsSize & 0xff), 0, 0, 0, 0, 0, 0]
        let records = answers.flatMap(\.wire)
        let whole = header(id: query.id, rd: query.recursionDesired, rcode: rcode, tc: false, qd: 1,
                           an: answers.count, ar: opt.isEmpty ? 0 : 1) + query.question + records + opt
        if whole.count <= limit { return (whole, false) }
        let cut = header(id: query.id, rd: query.recursionDesired, rcode: rcode, tc: true, qd: 1, an: 0,
                         ar: opt.isEmpty ? 0 : 1) + query.question + opt
        return (cut, true)
    }

    /// A reply with `rcode` and no records, the question echoed when there is one.
    public static func refusal(id: UInt16, rd: Bool, rcode: UInt8, question: [UInt8]) -> [UInt8] {
        header(id: id, rd: rd, rcode: rcode, tc: false, qd: question.isEmpty ? 0 : 1, an: 0, ar: 0) + question
    }

    static func header(id: UInt16, rd: Bool, rcode: UInt8, tc: Bool, qd: Int, an: Int, ar: Int) -> [UInt8] {
        let first: UInt8 = 0x80 | (tc ? 0x02 : 0) | (rd ? 0x01 : 0)
        return [UInt8(id >> 8), UInt8(id & 0xff), first, 0x80 | (rcode & 0x0f),
                0, UInt8(qd), UInt8(an >> 8), UInt8(an & 0xff), 0, 0, UInt8(ar >> 8), UInt8(ar & 0xff)]
    }

    static func name(_ labels: [[UInt8]]) -> [UInt8] {
        labels.flatMap { [UInt8($0.count)] + $0 } + [0]
    }
}

import Foundation
import Network
import os
import Security
import TopoProxy
import TopoUserland
import XCTest

/// The guest fetching software through the egress proxy, in the booted guest: `apk add` and
/// `git clone` go out through an `EgressProxy` in this process, over its real `URLSessionEgress`,
/// whose origin seam fronts a stub on loopback for every host on the list, so nothing here reaches
/// the internet and the list is not widened. The apk repository is an index the guest's own apk
/// makes from a pinned package and this test signs with a key it makes; the git repository is one
/// the guest makes and serves over git's dumb HTTP protocol. Both fail with the proxy stopped.
final class GuestBootstrapTests: XCTestCase {
    private var root: URL!
    private var point: String!
    private var origin: StaticOrigin?
    private var proxy: EgressProxy?
    private let lines = Lines()

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ line: String) { lock.withLock { all.append(line) } }
        var text: String { lock.withLock { all.joined(separator: "\n") } }
    }

    override func setUp() async throws {
        _ = try SharedGuest.booted()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        point = "/opt/bootstrap-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mount(root, at: point)
    }

    override func tearDown() async throws {
        await proxy?.stop()
        origin?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// An egress proxy whose every allowlisted host is the stub serving `root`; the guest's
    /// environment with its variables.
    private func started() async throws -> [String: String] {
        let origin = try StaticOrigin(root: root)
        self.origin = origin
        let originPort = try await origin.start()
        let lines = lines
        let proxy = try EgressProxy(upstream: URLSessionEgress(origin: { _ in URL(string: "http://127.0.0.1:\(originPort)")! }),
                                    log: { lines.add($0) })
        self.proxy = proxy
        let port = try await proxy.start()
        var environment = Guest.environment
        environment.merge(EgressProxy.guestEnvironment(port: port)) { _, new in new }
        return environment
    }

    private func sh(_ script: String, _ environment: [String: String] = Guest.environment) async throws -> Guest.Exit {
        try await Guest.shared.run("/bin/sh", ["-c", script], environment: environment)
    }

    func testGitAndGhArePresentAtBoot() async throws {
        let git = try await sh("git --version")
        XCTAssertEqual(git.status, 0, git.errors)
        XCTAssertEqual(git.output, "git version 2.49.1\n")
        let gh = try await sh("command -v gh && [ -x \"$(command -v gh)\" ]")
        XCTAssertEqual(gh.status, 0, gh.errors)
        XCTAssertEqual(gh.output, "/usr/bin/gh\n")
    }

    func testTheRepositoriesAreOverHTTP() async throws {
        let exit = try await sh("cat /etc/apk/repositories")
        XCTAssertEqual(exit.output, "http://dl-cdn.alpinelinux.org/alpine/v3.22/main\nhttp://dl-cdn.alpinelinux.org/alpine/v3.22/community\n")
    }

    /// `apk add` from a signed repository at an allowlisted name, through the proxy; and not at
    /// all with the proxy stopped.
    func testApkAddGoesThroughTheProxy() async throws {
        let package = try XCTUnwrap(try Fixture.shell().first { $0.file.lastPathComponent.hasPrefix("git-init-template-") })
        let name = package.file.lastPathComponent
        // The index is the architecture's; the package is `noarch`, which is where apk asks for it.
        let repository = root.appendingPathComponent("topo-test/aarch64", isDirectory: true)
        let noarch = root.appendingPathComponent("topo-test/noarch", isDirectory: true)
        let keys = root.appendingPathComponent("keys", isDirectory: true)
        for directory in [repository, noarch, keys] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: package.file, to: noarch.appendingPathComponent(name))
        // The guest's own apk makes the index; this test signs it as abuild-sign does, with a key
        // the guest is told to trust beside Alpine's own.
        let indexed = try await sh("apk index -q -o \(point!)/unsigned.tar.gz \(point!)/topo-test/noarch/\(name) && cp /etc/apk/keys/* \(point!)/keys/")
        XCTAssertEqual(indexed.status, 0, indexed.errors)
        let signer = try ApkSigner()
        let unsigned = try Data(contentsOf: root.appendingPathComponent("unsigned.tar.gz"))
        try signer.signed(index: unsigned).write(to: repository.appendingPathComponent("APKINDEX.tar.gz"))
        try Data(signer.publicKeyPEM.utf8).write(to: keys.appendingPathComponent(ApkSigner.keyName))

        let environment = try await started()
        let add = "apk add --no-cache --repositories-file /dev/null --keys-dir \(point!)/keys "
            + "--repository http://dl-cdn.alpinelinux.org/topo-test git-init-template"
        let exit = try await sh(add, environment)
        XCTAssertEqual(exit.status, 0, exit.output + exit.errors + "\nproxy: " + lines.text)
        XCTAssertFalse((exit.output + exit.errors).contains("UNTRUSTED"), exit.output + exit.errors)
        let installed = try await sh("apk info -e git-init-template")
        XCTAssertEqual(installed.output, "git-init-template\n")
        XCTAssertTrue(lines.text.contains("GET dl-cdn.alpinelinux.org /topo-test/aarch64/APKINDEX.tar.gz 200"), lines.text)
        XCTAssertTrue(lines.text.contains("GET dl-cdn.alpinelinux.org /topo-test/noarch/\(name) 200"), lines.text)

        await proxy?.stop()
        let removed = try await sh("apk del --no-cache --repositories-file /dev/null git-init-template >/dev/null")
        XCTAssertEqual(removed.status, 0, removed.errors)
        let stopped = try await sh(add, environment)
        XCTAssertNotEqual(stopped.status, 0, "apk added a package with the proxy stopped: " + stopped.output)
    }

    /// `git clone` of an `https://github.com/…` URL, rewritten to `http://` by the environment's
    /// configuration, through the proxy over git's dumb HTTP protocol; and not with the proxy
    /// stopped.
    func testGitCloneGoesThroughTheProxy() async throws {
        let made = try await sh("""
            set -e
            rm -rf /tmp/bootstrap-src && git init -q /tmp/bootstrap-src && cd /tmp/bootstrap-src
            echo through the egress proxy > README
            git add README && git -c user.name=topo -c user.email=topo@example.invalid commit -qm first
            mkdir -p \(point!)/samdu && git clone -q --bare /tmp/bootstrap-src \(point!)/samdu/probe.git
            # The mount's files are the host's, owned by nobody the guest is.
            git -c safe.directory='*' -C \(point!)/samdu/probe.git update-server-info
            """)
        XCTAssertEqual(made.status, 0, made.errors)

        let environment = try await started()
        let clone = try await sh("rm -rf /tmp/bootstrap-clone && git clone -q https://github.com/samdu/probe.git /tmp/bootstrap-clone && cat /tmp/bootstrap-clone/README", environment)
        XCTAssertEqual(clone.status, 0, clone.errors + "\nproxy: " + lines.text)
        XCTAssertEqual(clone.output, "through the egress proxy\n")
        XCTAssertTrue(lines.text.contains("GET github.com /samdu/probe.git/info/refs 200"), lines.text)

        await proxy?.stop()
        let stopped = try await sh("rm -rf /tmp/bootstrap-clone && git clone -q https://github.com/samdu/probe.git /tmp/bootstrap-clone", environment)
        XCTAssertNotEqual(stopped.status, 0, "git cloned with the proxy stopped")
    }
}

/// A loopback HTTP origin serving the files under `root` by path, one request per connection, and
/// 404 for anything else.
final class StaticOrigin: @unchecked Sendable {
    private let listener: NWListener
    private let root: URL

    init(root: URL) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.root = root
    }

    func start() async throws -> UInt16 {
        let queue = DispatchQueue(label: "test.static-origin")
        listener.newConnectionHandler = { [root] connection in
            connection.start(queue: queue)
            Self.serve(connection, root: root, head: Data())
        }
        let once = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                let result: Result<UInt16, Error>?
                switch state {
                case .ready: result = .success(listener.port!.rawValue)
                case .failed(let error): result = .failure(error)
                default: result = nil
                }
                guard let result, once.withLock({ resumed in defer { resumed = true }; return !resumed }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private static func serve(_ connection: NWConnection, root: URL, head: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var head = head
            if let data { head.append(data) }
            guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { serve(connection, root: root, head: head) }
                return
            }
            let line = String(decoding: head[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")[0]
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1].prefix { $0 != "?" }) : "/"
            let file = root.appendingPathComponent(String(path.dropFirst()))
            var response: Data
            if !path.contains(".."), let body = try? Data(contentsOf: file), !file.hasDirectoryPath {
                response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
            } else {
                response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

/// Signs an apk index as `abuild-sign` does: an RSA signature (PKCS#1 v1.5, SHA-1) over the whole
/// gzipped index, in a file `.SIGN.RSA.<key name>` in a tar segment with no end-of-archive blocks,
/// gzipped and put in front of the index. The key is made here, per test.
struct ApkSigner {
    static let keyName = "topo-test.rsa.pub"
    let key: SecKey

    init() throws {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw error!.takeRetainedValue() }
        self.key = key
    }

    /// The public key as `SubjectPublicKeyInfo` PEM, which is what apk reads from its keys folder:
    /// Security exports PKCS#1, so the fixed prefix for a 2048-bit RSA key goes in front.
    var publicKeyPEM: String {
        let pkcs1 = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data
        var spki = Data([0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
                         0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00])
        spki.append(pkcs1)
        let lines = spki.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PUBLIC KEY-----\n\(lines)\n-----END PUBLIC KEY-----\n"
    }

    func signed(index: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA1, index as CFData, &error) as Data? else {
            throw error!.takeRetainedValue()
        }
        var out = Self.gzip(Self.tarEntry(name: ".SIGN.RSA.\(Self.keyName)", contents: signature))
        out.append(index)
        return out
    }

    /// One ustar entry, header and contents padded to a block, with no end-of-archive blocks.
    static func tarEntry(name: String, contents: Data) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int) { for (i, byte) in text.utf8.enumerated() { header[offset + i] = byte } }
        put(name, at: 0)
        put("0000644\0", at: 100)
        put("0000000\0", at: 108)
        put("0000000\0", at: 116)
        put(String(format: "%011o\0", contents.count), at: 124)
        put("00000000000\0", at: 136)
        put("        ", at: 148)
        header[156] = UInt8(ascii: "0")
        put("ustar\0", at: 257)
        put("00", at: 263)
        put("root", at: 265)
        put("root", at: 297)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o\0 ", sum), at: 148)
        var entry = Data(header)
        entry.append(contents)
        entry.append(Data(count: (512 - contents.count % 512) % 512))
        return entry
    }

    /// A gzip member of stored (uncompressed) deflate blocks.
    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        var offset = 0
        repeat {
            let count = min(65535, data.count - offset)
            let final: UInt8 = offset + count == data.count ? 1 : 0
            out.append(final)
            out.append(contentsOf: [UInt8(count & 0xff), UInt8(count >> 8), UInt8(~count & 0xff), UInt8((~count >> 8) & 0xff)])
            out.append(data[data.startIndex + offset ..< data.startIndex + offset + count])
            offset += count
        } while offset < data.count
        for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] {
            out.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

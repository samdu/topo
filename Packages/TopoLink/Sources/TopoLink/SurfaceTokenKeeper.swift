import Foundation

/// The hub's `SurfaceTokens` as its keychain keeps them. A store that could not be read is not an
/// empty one: minting into it and saving would put every wall screen on a fresh address and forget
/// every revocation, so while it cannot be read it holds no tokens, takes no change and is
/// written never, and every `reload` asks again. Bytes that are there and do not decode are the
/// same: they are somebody's tokens, and the hub has no right to replace them with none.
public struct SurfaceTokenKeeper {
    /// The tokens, or nil while the store cannot be read.
    public private(set) var tokens: SurfaceTokens?
    /// Why the tokens cannot be read, or why the last change did not reach the store.
    public private(set) var trouble: String?
    private var owed = false
    private let read: () throws -> Data?
    private let write: (Data) throws -> Void

    public init(read: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void) {
        self.read = read
        self.write = write
        load()
    }

    /// Asks a store that could not be read again, and saves a change that did not land.
    public mutating func reload() {
        if tokens == nil { load() } else if owed { save() }
    }

    /// Changes the tokens and saves them. False, with nothing changed, while the store cannot be
    /// read. A save that fails leaves the change standing for this process, says so, and is tried
    /// again at the next `reload` or change.
    @discardableResult
    public mutating func change(_ body: (inout SurfaceTokens) -> Void) -> Bool {
        guard var changed = tokens else { return false }
        body(&changed)
        tokens = changed
        save()
        return true
    }

    private mutating func load() {
        do {
            guard let data = try read() else {
                tokens = SurfaceTokens()
                trouble = nil
                return
            }
            tokens = try JSONDecoder().decode(SurfaceTokens.self, from: data)
            trouble = nil
        } catch {
            tokens = nil
            trouble = "the screens' tokens cannot be read: \(error)"
        }
    }

    private mutating func save() {
        guard let tokens else { return }
        do {
            try write(JSONEncoder().encode(tokens))
            owed = false
            trouble = nil
        } catch {
            owed = true
            trouble = "the screens' tokens were not kept: \(error)"
        }
    }
}

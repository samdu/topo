import Foundation

enum TranscriptError: Error {
    /// No iCloud account on the device, or it is restricted. Womble has no
    /// sign-in of its own: the device's Apple ID is the whole of its access,
    /// so this is settled in Settings, not in the app.
    case noAccount
    /// No log exists on this Apple ID: nothing has ever written a turn, so
    /// the zone the writers create is not there.
    case noLog
    /// The store could not be reached. Nothing is wrong with the log; read
    /// again later.
    case unavailable(Error)
    /// The store refused the read and will keep refusing it: no permission,
    /// no such zone, a bad container. Retrying does not help.
    case rejected(Error)
}

/// Where the transcript is read from. One implementation reads CloudKit; the
/// tests read an array.
protocol TranscriptSource: AnyObject {
    /// Reads the whole log. The completion runs on the main queue.
    func read(completion: @escaping (Result<Transcript, TranscriptError>) -> Void)
}

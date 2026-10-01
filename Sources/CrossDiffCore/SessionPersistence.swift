import Foundation

/// Every operation for one session file shares a serial queue. A flush or clear waits for
/// older writes, so a delayed snapshot can never replace newer text or resurrect history.
public final class SessionPersistence: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "CrossDiff.session-persistence", qos: .utility)

    public init(url: URL) { self.url = url }

    public func save(_ snapshot: [StoredComparison],
                     completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [url] in
            completion(Result { try SessionFile.save(snapshot, to: url) })
        }
    }

    /// Intended for termination, where returning success must mean the newest snapshot is on disk.
    public func saveAndWait(_ snapshot: [StoredComparison]) throws {
        try queue.sync { try SessionFile.save(snapshot, to: url) }
    }

    public func clearAndWait() throws {
        try queue.sync { try SessionFile.clear(at: url) }
    }
}

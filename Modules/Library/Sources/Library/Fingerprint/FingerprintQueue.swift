import Acoustics
import Foundation
import Persistence

// MARK: - FingerprintQueue

/// Serialises concurrent identify requests so that `FingerprintService`'s
/// rate limiters are never overwhelmed by burst submissions from the UI.
///
/// Only one identify operation runs at a time (sequential). If the caller
/// cancels its `Task`, the in-flight operation completes normally (the
/// fingerprint may still be written to the DB), but no further items
/// from the queue are started.
public actor FingerprintQueue {
    private let service: FingerprintService

    public init(service: FingerprintService) {
        self.service = service
    }

    /// Submits an identify request and awaits the result.
    ///
    /// Callers should cancel their enclosing `Task` to abandon the request;
    /// `Task.checkCancellation()` is checked between queue items.
    public func identify(track: Track) async throws -> [IdentificationCandidate] {
        try Task.checkCancellation()
        return try await self.service.identify(track: track)
    }
}

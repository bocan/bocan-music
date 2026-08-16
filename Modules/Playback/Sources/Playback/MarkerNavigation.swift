import Foundation
import Persistence

// MARK: - MarkerNavigation

/// The pure CUE-marker transport rules (ADR-087), extracted so every
/// boundary condition is unit-testable without an engine. `QueuePlayer` is
/// the only caller; the strip, media keys, and the mini player inherit the
/// semantics through it.
enum MarkerNavigation {
    /// The restart threshold shared with track-level back (seconds).
    static let restartThreshold: TimeInterval = 3.0

    /// Where the forward button goes: the next marker past `elapsed`, or nil
    /// to advance the queue. The epsilon stops a jump that landed exactly on
    /// a boundary from re-targeting the same marker.
    static func nextTarget(markers: [TrackMarker], elapsed: TimeInterval) -> TimeInterval? {
        markers
            .map { Double($0.positionMs) / 1000.0 }
            .first { $0 > elapsed + 0.5 }
    }

    /// What the back button does.
    enum PreviousAction: Equatable {
        case seek(TimeInterval)
        case retreat
    }

    /// Track just started → retreat to the previous queue item (marker or
    /// not). Otherwise, at marker granularity: past the restart threshold
    /// inside the current marker → restart it; just entered it → the
    /// previous marker; in the first marker → the beginning.
    static func previousAction(markers: [TrackMarker], elapsed: TimeInterval) -> PreviousAction {
        guard elapsed > self.restartThreshold else { return .retreat }
        guard !markers.isEmpty else { return .seek(0) }
        let positions = markers.map { Double($0.positionMs) / 1000.0 }
        let currentStart = positions.last { $0 <= elapsed + 0.1 } ?? 0
        if elapsed - currentStart > self.restartThreshold {
            return .seek(currentStart)
        }
        if let previous = positions.last(where: { $0 < currentStart - 0.1 }) {
            return .seek(previous)
        }
        return .seek(0)
    }
}

import AppKit
import Persistence
import Playback

/// Registers a `willTerminateNotification` observer that saves the current
/// playback position to `UserDefaults` and runs an opportunistic
/// `incremental_vacuum` before the process exits.
///
/// A `DispatchSemaphore` blocks termination briefly while the async save
/// completes; the 2-second timeout prevents a hang on slow devices.  Vacuum
/// runs only when the freelist exceeds the threshold defined inside
/// `Database.vacuum()` (Phase 2 audit #5 / #17).
func registerTerminationObserver(player: QueuePlayer, database: Database) {
    NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification,
        object: nil,
        queue: nil
    ) { _ in
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await player.savePositionForSuspend()
            // Best-effort vacuum; never block quit on a DB error.
            _ = try? await database.vacuum()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}

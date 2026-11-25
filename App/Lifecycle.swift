import Persistence
import Playback

/// Adds the quit job that saves the current playback position to
/// `UserDefaults` and runs an opportunistic `incremental_vacuum` before the
/// process exits.
///
/// `QuitWork` bounds the wait (`QuitWork.limit`) so a slow device cannot hang
/// the quit. Vacuum runs only when the freelist exceeds the threshold defined
/// inside `Database.vacuum()` (ADR-003 audit #5 / #17).
@MainActor
func registerPlaybackQuitWork(player: QueuePlayer, database: Database, quitWork: QuitWork) {
    quitWork.add {
        await player.savePositionForSuspend()
        // Best-effort vacuum; never block quit on a DB error.
        _ = try? await database.vacuum()
    }
}

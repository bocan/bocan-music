import Foundation
import Observability
import Persistence

// MARK: - QueuePersistencePayload (Codable snapshot)

private struct QueuePayload: Codable {
    var items: [QueueItem]
    var currentIndex: Int?
    var repeatMode: RepeatMode
    var shuffleState: ShuffleState
}

// MARK: - QueuePersistence

/// Saves and restores the playback queue from the `settings` table.
///
/// Key: `"playback.queue.v1"` (Codable JSON blob via `SettingsRepository`).
/// Called by `QueuePlayer` on every queue mutation (debounced to 1 save / 2 s).
public actor QueuePersistence {
    private static let settingsKey = "playback.queue.v1"
    private static let debounceNanoseconds: UInt64 = 2_000_000_000 // 2 s

    private let repo: SettingsRepository
    private let log = AppLogger.make(.playback)
    private var pendingSave: Task<Void, Never>?

    public init(database: Database) {
        self.repo = SettingsRepository(database: database)
    }

    // MARK: - Save

    /// Debounced save. Multiple rapid calls within 2 s coalesce into one write.
    public func scheduleSave(
        items: [QueueItem],
        currentIndex: Int?,
        repeatMode: RepeatMode,
        shuffleState: ShuffleState
    ) {
        self.pendingSave?.cancel()
        self.pendingSave = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.flush(
                items: items,
                currentIndex: currentIndex,
                repeatMode: repeatMode,
                shuffleState: shuffleState
            )
        }
    }

    // MARK: - Restore

    /// Returns the previously persisted queue, or `nil` if none exists.
    public func restore() async -> (items: [QueueItem], currentIndex: Int?, repeatMode: RepeatMode, shuffleState: ShuffleState)? {
        do {
            guard let payload: QueuePayload = try await repo.get(QueuePayload.self, for: Self.settingsKey) else {
                return nil
            }
            self.log.debug("queue.restore", ["count": payload.items.count])
            return (payload.items, payload.currentIndex, payload.repeatMode, payload.shuffleState)
        } catch {
            self.log.error("queue.restore.failed", ["error": String(reflecting: error)])
            return nil
        }
    }

    // MARK: - Private

    private func flush(
        items: [QueueItem],
        currentIndex: Int?,
        repeatMode: RepeatMode,
        shuffleState: ShuffleState
    ) async {
        let payload = QueuePayload(
            items: items,
            currentIndex: currentIndex,
            repeatMode: repeatMode,
            shuffleState: shuffleState
        )
        do {
            try await self.repo.set(payload, for: Self.settingsKey)
            self.log.debug("queue.saved", ["count": items.count])
        } catch {
            self.log.error("queue.save.failed", ["error": String(reflecting: error)])
        }
    }
}

import Foundation
import Observability
import Persistence

// MARK: - PersistedQueueItem

/// Slim Codable DTO used for queue persistence.
///
/// Deliberately **omits** `BookmarkBlob` from `QueueItem`. Each bookmark is a
/// security-scoped binary blob (typically 2–8 KB per file). With 14 000+ items
/// that adds up to 100+ MB of Base64 in the JSON payload, causing a background-
/// thread CPU/memory spike that starves the CoreAudio IOWorkLoop and produces
/// audible pops. Bookmarks are re-fetched from the Library database as needed;
/// until then playback falls back to `fileURL` directly.
private struct PersistedQueueItem: Codable {
    let id: UUID
    let trackID: Int64
    let fileURL: String
    let duration: TimeInterval
    let sourceFormat: AudioSourceFormat
    let title: String?
    let artistName: String?
    let genre: String?
    let rating: Int
    let loved: Bool
    let playCount: Int
    let excludedFromShuffle: Bool
    let lastPlayedAt: Int64?
    let albumID: Int64?
    let artistID: Int64?

    init(from item: QueueItem) {
        self.id = item.id
        self.trackID = item.trackID
        self.fileURL = item.fileURL
        self.duration = item.duration
        self.sourceFormat = item.sourceFormat
        self.title = item.title
        self.artistName = item.artistName
        self.genre = item.genre
        self.rating = item.rating
        self.loved = item.loved
        self.playCount = item.playCount
        self.excludedFromShuffle = item.excludedFromShuffle
        self.lastPlayedAt = item.lastPlayedAt
        self.albumID = item.albumID
        self.artistID = item.artistID
    }

    func toQueueItem() -> QueueItem {
        QueueItem(
            id: self.id,
            trackID: self.trackID,
            bookmark: nil, // re-fetched from Library database on demand
            fileURL: self.fileURL,
            duration: self.duration,
            sourceFormat: self.sourceFormat,
            title: self.title,
            artistName: self.artistName,
            genre: self.genre,
            rating: self.rating,
            loved: self.loved,
            playCount: self.playCount,
            excludedFromShuffle: self.excludedFromShuffle,
            lastPlayedAt: self.lastPlayedAt,
            albumID: self.albumID,
            artistID: self.artistID
        )
    }
}

// MARK: - QueuePersistencePayload (Codable snapshot)

private struct QueuePayload: Codable {
    var items: [PersistedQueueItem]
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
            let items = payload.items.map { $0.toQueueItem() }
            self.log.debug("queue.restore", ["count": items.count])
            return (items, payload.currentIndex, payload.repeatMode, payload.shuffleState)
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
        // Strip the BookmarkBlob before encoding — each bookmark is 2–8 KB of binary
        // data, so 14k items can produce 100+ MB of Base64 JSON. That allocation spike
        // starves the CoreAudio IOWorkLoop even at .background priority and causes pops.
        // Bookmarks are not needed for restore: QueueItem falls back to fileURL directly.
        let slimItems = items.map { PersistedQueueItem(from: $0) }
        let payload = QueuePayload(
            items: slimItems,
            currentIndex: currentIndex,
            repeatMode: repeatMode,
            shuffleState: shuffleState
        )
        let repo = self.repo
        let log = self.log
        let count = items.count
        await Task.detached(priority: .background) {
            do {
                try await repo.set(payload, for: QueuePersistence.settingsKey)
                log.debug("queue.saved", ["count": count])
            } catch {
                log.error("queue.save.failed", ["error": String(reflecting: error)])
            }
        }.value
    }
}

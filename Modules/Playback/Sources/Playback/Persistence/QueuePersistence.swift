import Foundation
import Observability
import Persistence

// MARK: - PersistedQueueItemV2

/// Codable DTO used for queue persistence (schema v2).
///
/// Adds `playableSource` so remote Subsonic items round-trip correctly.
/// Like the v1 shape, this deliberately **omits** the security-scoped
/// `BookmarkBlob` from `QueueItem` — each bookmark is a 2–8 KB binary
/// blob and 14 000+ items can produce 100+ MB of Base64 in the JSON
/// payload, which starves the CoreAudio IOWorkLoop and causes audible
/// pops. Bookmarks are re-fetched from the Library database on demand.
private struct PersistedQueueItemV2: Codable {
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
    let playableSource: PlayableSource

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
        self.playableSource = item.playableSource
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
            artistID: self.artistID,
            playableSource: self.playableSource
        )
    }
}

// MARK: - PersistedQueueItemV1 (legacy)

/// Legacy queue item shape without `playableSource`. Decoded only during a
/// one-shot migration on first launch after upgrading to schema v2.
private struct PersistedQueueItemV1: Codable {
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

    func toQueueItem() -> QueueItem {
        QueueItem(
            id: self.id,
            trackID: self.trackID,
            bookmark: nil,
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
            artistID: self.artistID,
            playableSource: .localBookmark(Data())
        )
    }
}

// MARK: - Codable payloads

private struct QueuePayloadV2: Codable {
    /// Schema version written by this build.  Old blobs without a `version`
    /// field decode as `2` (the original v2 schema).  A future build that
    /// bumps this number will be detectable by downgraded builds.
    var version: Int
    var items: [PersistedQueueItemV2]
    var currentIndex: Int?
    var repeatMode: RepeatMode
    var shuffleState: ShuffleState

    private enum CodingKeys: String, CodingKey {
        case version, items, currentIndex, repeatMode, shuffleState
    }

    /// Forward-compatible decoder: `version` defaults to `2` so blobs written
    /// before this field was added continue to decode correctly.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        self.items = try c.decode([PersistedQueueItemV2].self, forKey: .items)
        self.currentIndex = try c.decodeIfPresent(Int.self, forKey: .currentIndex)
        self.repeatMode = try c.decode(RepeatMode.self, forKey: .repeatMode)
        self.shuffleState = try c.decode(ShuffleState.self, forKey: .shuffleState)
    }

    init(
        version: Int,
        items: [PersistedQueueItemV2],
        currentIndex: Int?,
        repeatMode: RepeatMode,
        shuffleState: ShuffleState
    ) {
        self.version = version
        self.items = items
        self.currentIndex = currentIndex
        self.repeatMode = repeatMode
        self.shuffleState = shuffleState
    }
}

private struct QueuePayloadV1: Codable {
    var items: [PersistedQueueItemV1]
    var currentIndex: Int?
    var repeatMode: RepeatMode
    var shuffleState: ShuffleState
}

// MARK: - QueuePersistence

/// Saves and restores the playback queue from the `settings` table.
///
/// Active key: `"playback.queue.v2"` (Codable JSON blob via
/// `SettingsRepository`). The v2 schema adds `PlayableSource` per item so
/// remote Subsonic tracks survive a relaunch. On first launch after the
/// upgrade, any legacy `"playback.queue.v1"` blob is read, every item is
/// promoted to `.localBookmark(Data())`, persisted under v2, and the v1
/// key is deleted.
public actor QueuePersistence {
    static let settingsKeyV1 = "playback.queue.v1"
    static let settingsKeyV2 = "playback.queue.v2"
    /// The schema version this build writes.  Increment when adding fields
    /// to `QueuePayloadV2` that older builds cannot interpret.
    public static let currentSchemaVersion = 2

    private let repo: SettingsRepository
    private let log = AppLogger.make(.playback)
    /// How long `scheduleSave` coalesces rapid calls before writing. Injectable
    /// so tests can collapse the window instead of sleeping past the 2 s default.
    private let debounce: Duration
    private var pendingSave: Task<Void, Never>?

    public init(database: Database, debounce: Duration = .seconds(2)) {
        self.repo = SettingsRepository(database: database)
        self.debounce = debounce
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
        let debounce = self.debounce
        self.pendingSave = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.flush(
                items: items,
                currentIndex: currentIndex,
                repeatMode: repeatMode,
                shuffleState: shuffleState
            )
        }
    }

    #if DEBUG
        /// Awaits the in-flight debounced save, if any. Test-only seam so suites can
        /// deterministically wait for `scheduleSave` to complete (through its
        /// debounce and flush) instead of sleeping past a guessed window (#323).
        func _awaitPendingSaveForTesting() async {
            await self.pendingSave?.value
        }
    #endif

    // MARK: - Restore

    /// Returns the previously persisted queue, or `nil` if none exists.
    ///
    /// Also returns a human-readable `schemaWarning` string when the on-disk
    /// blob was written by a *newer* build (i.e. its `version` field exceeds
    /// ``currentSchemaVersion``).  In that case the blob is discarded and the
    /// queue starts empty; callers should surface the warning to the user.
    ///
    /// Transparently migrates a legacy v1 blob to v2 on first read.
    public func restore() async -> (
        items: [QueueItem],
        currentIndex: Int?,
        repeatMode: RepeatMode,
        shuffleState: ShuffleState,
        schemaWarning: String?
    )? {
        do {
            if let payload: QueuePayloadV2 = try await repo.get(QueuePayloadV2.self, for: Self.settingsKeyV2) {
                // Guard against future-version blobs written by a newer build.
                if payload.version > Self.currentSchemaVersion {
                    self.log.warning("queue.restore.future_schema", [
                        "on_disk": payload.version,
                        "build": Self.currentSchemaVersion,
                    ])
                    // Delete the incompatible blob so we don't hit this on every launch.
                    try? await self.repo.remove(key: Self.settingsKeyV2)
                    return (
                        items: [],
                        currentIndex: nil,
                        repeatMode: .off,
                        shuffleState: .off,
                        schemaWarning: "Saved queue is from a newer version of Bòcan — starting fresh."
                    )
                }
                let items = payload.items.map { $0.toQueueItem() }
                self.log.debug("queue.restore", ["count": items.count, "schema": payload.version])
                return (items, payload.currentIndex, payload.repeatMode, payload.shuffleState, nil)
            }
            if let legacy: QueuePayloadV1 = try await repo.get(QueuePayloadV1.self, for: Self.settingsKeyV1) {
                let items = legacy.items.map { $0.toQueueItem() }
                self.log.info("queue.restore.migrate.v1.v2", ["count": items.count])
                await self.flush(
                    items: items,
                    currentIndex: legacy.currentIndex,
                    repeatMode: legacy.repeatMode,
                    shuffleState: legacy.shuffleState
                )
                try? await self.repo.remove(key: Self.settingsKeyV1)
                return (items, legacy.currentIndex, legacy.repeatMode, legacy.shuffleState, nil)
            }
            return nil
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
        let slimItems = items.map { PersistedQueueItemV2(from: $0) }
        let payload = QueuePayloadV2(
            version: QueuePersistence.currentSchemaVersion,
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
                try await repo.set(payload, for: QueuePersistence.settingsKeyV2)
                log.debug("queue.saved", ["count": count, "schema": 2])
            } catch {
                log.error("queue.save.failed", ["error": String(reflecting: error)])
            }
        }.value
    }
}

import AudioEngine
import Foundation
import Library
import Observability
import Persistence

// MARK: - ArtifactEncoding

/// Seam over `AudioTranscoder` so coordinator tests run hermetically, without
/// FFmpeg or audio fixtures.
protocol ArtifactEncoding: Sendable {
    func encode(
        source: URL,
        destination: URL,
        preset: TranscodePreset,
        metadata: [String: String]
    ) async throws -> TranscodeResult
}

/// The production encoder: the AudioEngine transcoder, one file at a time.
struct AudioTranscoderEncoder: ArtifactEncoding {
    private let transcoder = AudioTranscoder()

    func encode(
        source: URL,
        destination: URL,
        preset: TranscodePreset,
        metadata: [String: String]
    ) async throws -> TranscodeResult {
        try await self.transcoder.transcode(source: source, to: destination, preset: preset, metadata: metadata)
    }
}

// MARK: - TranscodeCoordinator

/// Prepare-and-release for transcoded sync (ADR-088): keeps the ledger and
/// workspace in step with the sync profile.
///
/// Idle unless the profile names a preset. A pass: clears other rungs and
/// stale or deselected rows, releases served bytes (unless the keep toggle is
/// on), then encodes what is missing, one file at a time, until done or the
/// prepare window is full. Ledger writes bump the sync generation through the
/// observed-tables machinery, so the phone discovers newly prepared tracks on
/// its next poll and the sync grows as the pass progresses.
public actor TranscodeCoordinator {
    private let profileRepository: SyncProfileRepository
    private let ledger: SyncTranscodeRepository
    private let tracks: TrackRepository
    private let artists: ArtistRepository
    private let albums: AlbumRepository
    private let syncMeta: SyncMetaRepository
    private let membership: ProfileMembership
    private let store: TranscodeStore
    private let encoder: any ArtifactEncoding
    private let prepareWindowBytes: Int64
    private let debounce: Duration
    private let log = AppLogger.make(.sync)

    private var running = false
    private var observationTask: Task<Void, Never>?
    private var pendingPass: Task<Void, Never>?
    private var urgentTrackIDs: [Int64] = []
    private var passRunning = false
    /// Set when a change event lands while a pass is running (a pass's own
    /// ledger writes come back through the observation): the pass finishes
    /// its work and then schedules one follow-up, instead of the event
    /// cancelling the encode in flight. Internal so tests can observe it.
    private(set) var rerunRequested = false
    /// One entry per encode failure this app-run. Later passes skip these,
    /// so one damaged file cannot tax every pass. Keyed by source hash, so
    /// a repaired or retagged file gets a fresh try.
    private var failedEncodes: Set<FailedEncode> = []

    struct FailedEncode: Hashable {
        let trackID: Int64
        let preset: String
        let sourceContentHash: String
    }

    init(
        database: Database,
        store: TranscodeStore,
        encoder: any ArtifactEncoding = AudioTranscoderEncoder(),
        prepareWindowBytes: Int64,
        debounce: Duration
    ) {
        self.profileRepository = SyncProfileRepository(database: database)
        self.ledger = SyncTranscodeRepository(database: database)
        self.tracks = TrackRepository(database: database)
        self.artists = ArtistRepository(database: database)
        self.albums = AlbumRepository(database: database)
        self.syncMeta = SyncMetaRepository(database: database)
        self.membership = ProfileMembership(
            playlistRepository: PlaylistRepository(database: database),
            smartService: SmartPlaylistService(database: database)
        )
        self.store = store
        self.encoder = encoder
        self.prepareWindowBytes = prepareWindowBytes
        self.debounce = debounce
    }

    // MARK: - Lifecycle

    /// Starts observing library and profile changes and schedules an initial
    /// pass (a preset chosen while the server was stopped gets picked up).
    public func start() {
        guard !self.running else { return }
        self.running = true
        self.observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.syncMeta.observeLibraryChanges()
            do {
                var isInitial = true
                for try await _ in stream {
                    if isInitial {
                        isInitial = false
                        continue
                    }
                    await self.schedulePass()
                }
            } catch {
                await self.observationFailed(error)
            }
        }
        self.schedulePass()
    }

    public func stop() {
        self.running = false
        self.observationTask?.cancel()
        self.observationTask = nil
        self.pendingPass?.cancel()
        self.pendingPass = nil
    }

    /// Puts a track at the head of the queue (a request arrived for released
    /// bytes; the 503-busy path of ADR-088) and schedules a pass. The phone
    /// is waiting, so this is the one caller allowed to interrupt a running
    /// pass; a failure memo for the track is cleared for one fresh try.
    public func requestUrgent(trackID: Int64) {
        if !self.urgentTrackIDs.contains(trackID) {
            self.urgentTrackIDs.insert(trackID, at: 0)
        }
        self.failedEncodes = self.failedEncodes.filter { $0.trackID != trackID }
        self.schedulePass(interrupt: true)
    }

    /// Debounced pass scheduling: a burst of changes runs one pass. While a
    /// pass is running, a non-interrupting call defers to a follow-up pass
    /// instead of cancelling the work in flight (the coordinator's own
    /// ledger writes fire the same observation stream).
    private func schedulePass(interrupt: Bool = false) {
        guard self.running else { return }
        if self.passRunning, !interrupt {
            self.rerunRequested = true
            return
        }
        self.pendingPass?.cancel()
        self.pendingPass = Task { [weak self, debounce] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return // Cancelled: a newer pass is scheduled, or we stopped.
            }
            await self?.runPass()
        }
    }

    private func observationFailed(_ error: any Error) {
        self.log.warning("transcode.observe.failed", ["error": String(reflecting: error)])
    }

    // MARK: - The pass

    /// Internal so tests can drive a pass deterministically; production entry
    /// is always the debounced `schedulePass`. A pass runs even while
    /// `running` is false in tests (the guard lives in `schedulePass`).
    func runPass() async {
        let started = Date()
        self.passRunning = true
        self.rerunRequested = false
        var cancelled = false
        do {
            try await self.pass()
            self.log.debug("transcode.pass.end", ["ms": "\(Int(Date().timeIntervalSince(started) * 1000))"])
        } catch is CancellationError {
            cancelled = true
            self.log.debug("transcode.pass.cancelled")
        } catch {
            self.log.warning("transcode.pass.failed", ["error": String(reflecting: error)])
        }
        self.passRunning = false
        // Changes that arrived mid-pass get one follow-up pass; a cancelled
        // pass leaves scheduling to whoever cancelled it (stop or urgent).
        if !cancelled, self.rerunRequested {
            self.rerunRequested = false
            self.schedulePass()
        }
    }

    private func pass() async throws {
        let document = try await SyncProfileDocument.decode(self.profileRepository.profileJSON())
        guard let preset = document.transcode.preset else {
            try await self.clearAllRungs()
            return
        }
        try await self.clearOtherRungs(than: preset)
        try await self.clearStaleRows(preset: preset)

        let targets = try await self.transcodeTargets(profile: document.profile, preset: preset)
        let targetIDs = Set(targets.compactMap(\.id))
        let valid = try await self.reconcileLedger(
            preset: preset,
            targetIDs: targetIDs,
            keepArtifacts: document.transcode.keepArtifacts
        )

        try await self.encodeMissing(targets: targets, valid: valid, preset: preset)
    }

    /// Original selected: every rung's rows and bytes go.
    private func clearAllRungs() async throws {
        for preset in TranscodePreset.allCases {
            let removed = try await self.ledger.deleteAll(preset: preset.rawValue)
            self.store.removePreset(preset)
            if removed > 0 {
                self.log.debug("transcode.rung.cleared", ["preset": preset.rawValue, "rows": "\(removed)"])
            }
        }
    }

    private func clearOtherRungs(than preset: TranscodePreset) async throws {
        for other in TranscodePreset.allCases where other != preset {
            let removed = try await self.ledger.deleteAll(preset: other.rawValue)
            self.store.removePreset(other)
            if removed > 0 {
                self.log.debug("transcode.rung.cleared", ["preset": other.rawValue, "rows": "\(removed)"])
            }
        }
    }

    /// Rows whose source hash no longer matches (retags) lose bytes and rows.
    private func clearStaleRows(preset: TranscodePreset) async throws {
        let stale = try await self.ledger.deleteStale(preset: preset.rawValue)
        for row in stale {
            self.store.removeArtifact(
                trackID: row.trackID,
                sourceContentHash: row.sourceContentHash,
                preset: preset
            )
        }
    }

    /// The tracks the profile selects that the predicate marks for
    /// transcoding: lossless, or lossy above the target bitrate (ADR-088).
    private func transcodeTargets(profile: SyncProfile, preset: TranscodePreset) async throws -> [Track] {
        let selected = try await self.membership.selectedTrackIDs(profile: profile)
        return try await self.tracks.fetchAllIncludingDisabled()
            .filter { !$0.disabled }
            .filter { $0.contentHash != nil }
            .filter { track in track.id.map { selected?.contains($0) ?? true } ?? false }
            .filter { Self.needsTranscode($0, preset: preset) }
    }

    static func needsTranscode(_ track: Track, preset: TranscodePreset) -> Bool {
        if track.isLossless == true { return true }
        if let bitrate = track.bitrate, bitrate > preset.targetKbps { return true }
        return false
    }

    /// Drops rows for tracks that left the target set and releases served
    /// bytes (prepare-and-release), then returns the surviving valid rows.
    private func reconcileLedger(
        preset: TranscodePreset,
        targetIDs: Set<Int64>,
        keepArtifacts: Bool
    ) async throws -> [SyncTranscode] {
        var valid = try await self.ledger.allValid(preset: preset.rawValue)
        for row in valid where !targetIDs.contains(row.trackID) {
            try await self.ledger.delete(trackID: row.trackID, preset: preset.rawValue)
            self.store.removeArtifact(
                trackID: row.trackID,
                sourceContentHash: row.sourceContentHash,
                preset: preset
            )
        }
        valid.removeAll { !targetIDs.contains($0.trackID) }

        if !keepArtifacts {
            for row in valid where row.servedAt != nil {
                self.store.removeArtifact(
                    trackID: row.trackID,
                    sourceContentHash: row.sourceContentHash,
                    preset: preset
                )
            }
        }
        return valid
    }

    /// Encodes targets lacking a valid row, urgent requests first, until the
    /// prepare window fills. One failed file logs and moves on; only
    /// cancellation stops the pass.
    private func encodeMissing(targets: [Track], valid: [SyncTranscode], preset: TranscodePreset) async throws {
        let validIDs = Set(valid.map(\.trackID))
        var pending = targets.filter { track in
            guard let id = track.id, let hash = track.contentHash, !validIDs.contains(id) else { return false }
            let memo = FailedEncode(trackID: id, preset: preset.rawValue, sourceContentHash: hash)
            return !self.failedEncodes.contains(memo)
        }
        let urgent = self.urgentTrackIDs
        self.urgentTrackIDs.removeAll()
        pending.sort { lhs, rhs in
            let lhsUrgent = lhs.id.map { urgent.contains($0) } ?? false
            let rhsUrgent = rhs.id.map { urgent.contains($0) } ?? false
            if lhsUrgent != rhsUrgent { return lhsUrgent }
            return (lhs.id ?? 0) < (rhs.id ?? 0)
        }
        guard !pending.isEmpty else { return }

        var unservedBytes = valid
            .filter { $0.servedAt == nil }
            .filter { self.store.exists(trackID: $0.trackID, sourceContentHash: $0.sourceContentHash, preset: preset) }
            .reduce(Int64(0)) { $0 + $1.size }

        let artistName = try await Self.nameMap(self.artists.fetchAll().map { ($0.id, $0.name) })
        let albumTitle = try await Self.nameMap(self.albums.fetchAll().map { ($0.id, $0.title) })

        var prepared = 0
        for track in pending {
            // stop() cancels the pass's task, so cancellation is the one
            // mid-pass exit; a direct runPass() in tests runs to completion.
            try Task.checkCancellation()
            if unservedBytes >= self.prepareWindowBytes {
                self.log.debug("transcode.window.full", ["bytes": "\(unservedBytes)"])
                break
            }
            guard let id = track.id, let sourceHash = track.contentHash else { continue }
            do {
                let result = try await self.encodeOne(
                    track,
                    id: id,
                    sourceHash: sourceHash,
                    preset: preset,
                    artistName: artistName,
                    albumTitle: albumTitle
                )
                unservedBytes += result.size
                prepared += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.failedEncodes.insert(FailedEncode(
                    trackID: id,
                    preset: preset.rawValue,
                    sourceContentHash: sourceHash
                ))
                self.log.warning("transcode.encode.failed", [
                    "track": "\(id)",
                    "error": String(reflecting: error),
                ])
            }
        }
        if prepared > 0 {
            self.log.debug("transcode.prepared", ["count": "\(prepared)", "preset": preset.rawValue])
        }
    }

    private func encodeOne(
        _ track: Track,
        id: Int64,
        sourceHash: String,
        preset: TranscodePreset,
        artistName: [Int64: String],
        albumTitle: [Int64: String]
    ) async throws -> TranscodeResult {
        try self.store.prepareDirectory(preset: preset)
        let destination = self.store.artifactURL(trackID: id, sourceContentHash: sourceHash, preset: preset)
        let metadata = Self.metadata(for: track, artistName: artistName, albumTitle: albumTitle)

        // Hoisted so the security-scope closure captures only Sendable values,
        // never the actor itself (strict concurrency).
        let encoder = self.encoder
        let result: TranscodeResult
        if let bookmark = track.fileBookmark {
            result = try await SecurityScope.withAccess(bookmark) { url in
                try await encoder.encode(source: url, destination: destination, preset: preset, metadata: metadata)
            }
        } else if let url = URL(string: track.fileURL) {
            // No bookmark: the unsandboxed release build, or a test fixture.
            result = try await encoder.encode(source: url, destination: destination, preset: preset, metadata: metadata)
        } else {
            throw SyncServerError.transcodeSourceUnavailable(trackID: id)
        }

        try await self.ledger.upsert(SyncTranscode(
            trackID: id,
            preset: preset.rawValue,
            sourceContentHash: sourceHash,
            sha256: result.sha256,
            size: result.size,
            createdAt: Int64(Date().timeIntervalSince1970),
            bitrate: result.bitrateKbps
        ))
        return result
    }

    // MARK: - Helpers

    private static func nameMap(_ pairs: [(Int64?, String)]) -> [Int64: String] {
        var map: [Int64: String] = [:]
        for (id, name) in pairs {
            if let id { map[id] = name }
        }
        return map
    }

    /// The tags the artifact carries so the file is self-describing off-device.
    static func metadata(
        for track: Track,
        artistName: [Int64: String],
        albumTitle: [Int64: String]
    ) -> [String: String] {
        var tags: [String: String] = [:]
        if let title = track.title { tags["title"] = title }
        if let artistID = track.artistID, let name = artistName[artistID] { tags["artist"] = name }
        if let albumArtistID = track.albumArtistID, let name = artistName[albumArtistID] {
            tags["album_artist"] = name
        }
        if let albumID = track.albumID, let title = albumTitle[albumID] { tags["album"] = title }
        if let trackNumber = track.trackNumber { tags["track"] = "\(trackNumber)" }
        if let discNumber = track.discNumber { tags["disc"] = "\(discNumber)" }
        if let year = track.year { tags["date"] = "\(year)" }
        if let genre = track.genre { tags["genre"] = genre }
        return tags
    }
}

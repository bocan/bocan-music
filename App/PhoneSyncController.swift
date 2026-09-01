import AudioEngine
import Foundation
import Observability
import Persistence
import SyncServer
import UI

/// App-side implementation of the UI's `PhoneSyncControlling` seam over the
/// `SyncServer` actor plus the profile / playlist repositories and the manifest
/// builder (for the size estimate). Keeps `UI` independent of `SyncServer`.
final class PhoneSyncController: PhoneSyncControlling, @unchecked Sendable {
    private let server: SyncServer
    private let profileRepository: SyncProfileRepository
    private let playlistRepository: PlaylistRepository
    private let trackRepository: TrackRepository
    private let manifestBuilder: ManifestBuilder
    private let syncMeta: SyncMetaRepository
    private let log = AppLogger.make(.sync)

    init(
        server: SyncServer,
        profileRepository: SyncProfileRepository,
        playlistRepository: PlaylistRepository,
        trackRepository: TrackRepository,
        manifestBuilder: ManifestBuilder,
        syncMeta: SyncMetaRepository
    ) {
        self.server = server
        self.profileRepository = profileRepository
        self.playlistRepository = playlistRepository
        self.trackRepository = trackRepository
        self.manifestBuilder = manifestBuilder
        self.syncMeta = syncMeta
    }

    func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "sync.enabled")
    }

    func setEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: "sync.enabled")
        if enabled {
            do {
                try await self.server.start()
            } catch {
                self.log.error("sync.start.failed", ["error": String(reflecting: error)])
            }
        } else {
            await self.server.stop()
        }
    }

    func loadProfile() async -> PhoneSyncProfile {
        await Self.toUI(self.loadDocument().profile)
    }

    /// The stored profile document. Transcode settings (ADR-088) ride along
    /// so a save from this UI never clobbers them.
    private func loadDocument() async -> SyncProfileDocument {
        do {
            return try await SyncProfileDocument.decode(self.profileRepository.profileJSON())
        } catch {
            self.log.error("sync.profile.read.failed", ["error": String(reflecting: error)])
            return .default
        }
    }

    func saveProfile(_ profile: PhoneSyncProfile) async {
        var document = await self.loadDocument()
        document.profile = Self.toSync(profile)
        do {
            try await self.profileRepository.setProfileJSON(document.encoded())
        } catch {
            self.log.error("sync.profile.save.failed", ["error": String(reflecting: error)])
        }
    }

    func availablePlaylists() async -> [PhoneSyncPlaylist] {
        let all = await (try? self.playlistRepository.fetchAll()) ?? []
        return all.compactMap { playlist in
            playlist.id.map { PhoneSyncPlaylist(id: $0, name: playlist.name) }
        }
    }

    func sizeEstimate(for profile: PhoneSyncProfile) async -> PhoneSyncSizeEstimate {
        do {
            let estimate = try await self.manifestBuilder.sizeEstimate(for: Self.toSync(profile))
            return PhoneSyncSizeEstimate(
                bytes: estimate.bytes,
                trackCount: estimate.trackCount,
                episodeCount: estimate.episodeCount
            )
        } catch {
            self.log.warning("sync.estimate.failed", ["error": String(reflecting: error)])
            return .zero
        }
    }

    func pairedDevices() async -> [TrustedDevice] {
        await (try? self.server.pairedDevices()) ?? []
    }

    func observeHashingProgress() async -> AsyncThrowingStream<ContentHashProgress, Error> {
        await self.trackRepository.observeContentHashProgress()
    }

    // MARK: - Transcoding (ADR-088)

    func transcodeState() async -> PhoneSyncTranscodeState {
        let settings = await self.loadDocument().transcode
        return PhoneSyncTranscodeState(preset: settings.preset, keepArtifacts: settings.keepArtifacts)
    }

    func setTranscodeState(_ state: PhoneSyncTranscodeState) async {
        var document = await self.loadDocument()
        document.transcode = TranscodeSettings(preset: state.preset, keepArtifacts: state.keepArtifacts)
        do {
            try await self.profileRepository.setProfileJSON(document.encoded())
        } catch {
            self.log.error("sync.transcode.save.failed", ["error": String(reflecting: error)])
        }
    }

    func rungEstimates(for profile: PhoneSyncProfile) async -> [TranscodePreset?: PhoneSyncSizeEstimate] {
        do {
            let estimates = try await self.manifestBuilder.sizeEstimates(for: Self.toSync(profile))
            return estimates.mapValues {
                PhoneSyncSizeEstimate(bytes: $0.bytes, trackCount: $0.trackCount, episodeCount: $0.episodeCount)
            }
        } catch {
            self.log.warning("sync.estimate.failed", ["error": String(reflecting: error)])
            return [:]
        }
    }

    /// Recomputed on every library-change emission (the observed tables
    /// include the transcode ledger, so each prepared artifact ticks the row).
    func observeTranscodeProgress() async -> AsyncThrowingStream<PhoneSyncTranscodeProgress?, Error> {
        let changes = await self.syncMeta.observeLibraryChanges()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await _ in changes {
                        await continuation.yield(self.currentTranscodeProgress())
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func currentTranscodeProgress() async -> PhoneSyncTranscodeProgress? {
        let document = await self.loadDocument()
        guard let preset = document.transcode.preset else { return nil }
        do {
            let progress = try await self.manifestBuilder.transcodeProgress(for: document.profile, preset: preset)
            return PhoneSyncTranscodeProgress(prepared: progress.prepared, total: progress.total)
        } catch {
            self.log.warning("sync.transcode_progress.failed", ["error": String(reflecting: error)])
            return nil
        }
    }

    func revoke(fingerprint: String) async {
        do {
            try await self.server.revoke(fingerprint: fingerprint)
        } catch {
            self.log.error("sync.revoke.failed", ["error": String(reflecting: error)])
        }
    }

    func armPairing() async {
        await self.server.armPairing()
    }

    func cancelPairing() async {
        await self.server.cancelPairing()
    }

    // MARK: - Profile mapping

    private static func toUI(_ profile: SyncProfile) -> PhoneSyncProfile {
        switch profile {
        case let .everything(includePodcasts):
            PhoneSyncProfile(mode: .everything, selectedPlaylistIDs: [], includePodcasts: includePodcasts)

        case let .selected(playlistIds, includePodcasts):
            PhoneSyncProfile(
                mode: .choosePlaylists,
                selectedPlaylistIDs: Set(playlistIds),
                includePodcasts: includePodcasts
            )
        }
    }

    private static func toSync(_ profile: PhoneSyncProfile) -> SyncProfile {
        switch profile.mode {
        case .everything:
            .everything(includePodcasts: profile.includePodcasts)

        case .choosePlaylists:
            .selected(playlistIds: profile.selectedPlaylistIDs.sorted(), includePodcasts: profile.includePodcasts)
        }
    }
}

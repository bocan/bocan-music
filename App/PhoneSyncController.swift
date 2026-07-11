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
    private let manifestBuilder: ManifestBuilder
    private let log = AppLogger.make(.sync)

    init(
        server: SyncServer,
        profileRepository: SyncProfileRepository,
        playlistRepository: PlaylistRepository,
        manifestBuilder: ManifestBuilder
    ) {
        self.server = server
        self.profileRepository = profileRepository
        self.playlistRepository = playlistRepository
        self.manifestBuilder = manifestBuilder
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
        let stored = try? await self.profileRepository.profileJSON()
        let profile = stored
            .flatMap { try? JSONDecoder().decode(SyncProfile.self, from: $0) } ?? .default
        return Self.toUI(profile)
    }

    func saveProfile(_ profile: PhoneSyncProfile) async {
        guard let data = try? JSONEncoder().encode(Self.toSync(profile)) else { return }
        do {
            try await self.profileRepository.setProfileJSON(data)
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

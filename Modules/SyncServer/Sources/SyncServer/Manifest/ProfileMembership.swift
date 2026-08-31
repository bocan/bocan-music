import Foundation
import Library
import Persistence

/// The one profile-membership walk: which track ids the sync profile selects.
///
/// This logic used to live twice, flagged "keep in sync", in ManifestBuilder
/// and FileServing; the transcode coordinator (ADR-088) is the third
/// consumer, so it lives here now, exactly once.
struct ProfileMembership {
    private let playlistRepository: PlaylistRepository
    private let smartService: SmartPlaylistService

    init(playlistRepository: PlaylistRepository, smartService: SmartPlaylistService) {
        self.playlistRepository = playlistRepository
        self.smartService = smartService
    }

    /// The selected track ids, or `nil` for `.everything` so callers can
    /// short-circuit without materializing the whole library. Pass
    /// `playlists` when the caller already fetched them (the manifest build).
    func selectedTrackIDs(profile: SyncProfile, playlists: [Playlist]? = nil) async throws -> Set<Int64>? {
        switch profile {
        case .everything:
            return nil

        case let .selected(playlistIds, _):
            let all: [Playlist] = if let playlists {
                playlists
            } else {
                try await self.playlistRepository.fetchAll()
            }
            var ids: Set<Int64> = []
            for playlistId in playlistIds {
                try await self.gather(playlistId, playlists: all, into: &ids)
            }
            return ids
        }
    }

    private func gather(_ playlistId: Int64, playlists: [Playlist], into ids: inout Set<Int64>) async throws {
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else { return }
        switch playlist.kind {
        case .manual:
            try await ids.formUnion(self.playlistRepository.fetchTrackIDs(playlistID: playlistId))

        case .smart:
            try await ids.formUnion(self.smartService.tracks(for: playlistId).compactMap(\.id))

        case .folder:
            for child in playlists where child.parentID == playlistId {
                guard let childId = child.id else { continue }
                try await self.gather(childId, playlists: playlists, into: &ids)
            }
        }
    }
}

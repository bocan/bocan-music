import Foundation
import Persistence

// MARK: - LibraryViewModel + Love / Rating

/// Love and rating actions on the current track-table selection.
///
/// Used by the global Track menu commands (`⌘L`, `⌘1`–`⌘5`) and by the
/// right-click context menu.  Persists via `TrackRepository.update(_:)`
/// and refreshes affected rows so the UI reflects the change without
/// reloading the whole destination.
public extension LibraryViewModel {
    /// Toggles the `loved` flag on every track in the current selection.
    ///
    /// If the selection is heterogeneous (some loved, some not), all
    /// tracks become loved.  Otherwise the flag is flipped.
    func toggleLovedForCurrentSelection() {
        let selectedIDs = self.tracks.selection
        let selected = self.tracks.tracks.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        let newValue = !selected.allSatisfy(\.loved)
        Task { await self.applyLoved(newValue, to: selected) }
    }

    /// Sets the rating (0–5 stars, stored as 0–100) on every track in the
    /// current selection.
    ///
    /// - Parameter stars: 0–5.  Values outside the range are clamped.
    func setRatingForCurrentSelection(stars: Int) {
        let clamped = max(0, min(5, stars))
        let value = clamped * 20
        let selectedIDs = self.tracks.selection
        let selected = self.tracks.tracks.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        Task { await self.applyRating(value, to: selected) }
    }

    /// Sets the rating (0–5 stars, stored as 0–100) on explicit tracks,
    /// bypassing the ViewModel selection.  Used by the context menu, which
    /// already has the target tracks in hand.
    ///
    /// - Parameters:
    ///   - stars: 0–5.  Values outside the range are clamped.
    ///   - tracks: The tracks to update.
    func setRating(stars: Int, for tracks: [Track]) {
        let clamped = max(0, min(5, stars))
        let value = clamped * 20
        guard !tracks.isEmpty else { return }
        Task { await self.applyRating(value, to: tracks) }
    }

    // MARK: - Persistence helpers

    private func applyLoved(_ loved: Bool, to tracks: [Track]) async {
        let repo = TrackRepository(database: self.database)
        var updatedIDs: [Int64] = []
        for var track in tracks {
            track.loved = loved
            do {
                try await repo.update(track)
                if let id = track.id { updatedIDs.append(id) }
            } catch {
                self.log.error("library.love.failed", ["error": String(reflecting: error)])
            }
        }
        await self.refreshTracks(ids: updatedIDs)
    }

    private func applyRating(_ rating: Int, to tracks: [Track]) async {
        let repo = TrackRepository(database: self.database)
        var updatedIDs: [Int64] = []
        for var track in tracks {
            track.rating = rating
            do {
                try await repo.update(track)
                if let id = track.id { updatedIDs.append(id) }
            } catch {
                self.log.error("library.rating.failed", ["error": String(reflecting: error)])
            }
        }
        await self.refreshTracks(ids: updatedIDs)
    }
}

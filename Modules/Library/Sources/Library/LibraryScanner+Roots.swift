import Foundation
import Observability
import Persistence

// MARK: - Root removal and tracks outside every root

extension LibraryScanner {
    /// Removes a root by its database ID and soft-deletes the tracks it held.
    ///
    /// A track that another root still holds (a nested or overlapping folder)
    /// stays. The folder is no longer watched afterwards. Files on disk are
    /// not touched.
    public func removeRoot(id: Int64) async throws {
        // Fetch the roots before deleting so we can disable the root's tracks.
        let roots = try await self.rootRepo.fetchAll()
        try await self.rootRepo.delete(id: id)
        guard let root = roots.first(where: { $0.id == id }) else { return }

        let remaining = roots.filter { $0.id != id }
        let trackRepo = TrackRepository(database: self.database)
        let fileURLs = try await trackRepo.enabledFileURLs()
        let removed = RootCoverage(paths: self.paths(of: [root]))
        let kept = RootCoverage(paths: self.paths(of: remaining))
        let ids = removed.trackIDs(in: fileURLs, at: .inside).filter { id in
            guard let fileURL = fileURLs[id] else { return false }
            return kept.position(ofFileURL: fileURL) != .inside
        }
        let hidden = try await trackRepo.disable(ids: ids)
        if hidden > 0 {
            try await trackRepo.pruneAlbumsAndArtistsWithoutEnabledTracks()
        }
        self.log.info("library.root.removed", ["id": id, "path": root.path, "tracks": hidden])

        // A watcher that keeps following the folder would import new files
        // from it again. Start over from the roots that remain.
        if self.fsWatcher != nil {
            await self.stopWatching()
            await self.startWatching()
        }
    }

    /// Soft-deletes the enabled local tracks that no root holds, and returns
    /// how many there were.
    ///
    /// Such tracks are what a removed folder left behind before #643: nothing
    /// scans them, so nothing else would ever hide them, and a library moved
    /// to a new folder showed every song twice. Best effort: a failure is
    /// logged and counts as none.
    ///
    /// Nothing is hidden while any root cannot be reached (an unplugged
    /// drive, a deleted single-file source). Such a root's bookmark cannot be
    /// resolved, so only its stored path is known, and its tracks may be
    /// stored under another spelling of that place (through a symlink, or
    /// after a rename). They would look left behind when they are not.
    ///
    /// - Parameters:
    ///   - roots: Every persisted root, reachable or not.
    ///   - resolved: Where the reachable roots' bookmarks point now, which can
    ///     differ from the stored path after a folder is renamed.
    func hideTracksOutsideRoots(_ roots: [LibraryRoot], resolved: [URL]) async -> Int {
        guard !Task.isCancelled else { return 0 }
        guard resolved.count == roots.count else {
            self.log.debug("library.orphans.skipped", ["roots": roots.count, "reachable": resolved.count])
            return 0
        }
        let coverage = RootCoverage(paths: roots.map(\.path) + resolved.map(\.path))
        let trackRepo = TrackRepository(database: self.database)
        do {
            let ids = try await coverage.trackIDs(in: trackRepo.enabledFileURLs(), at: .outside)
            guard !ids.isEmpty else { return 0 }
            let hidden = try await trackRepo.disable(ids: ids)
            try await trackRepo.pruneAlbumsAndArtistsWithoutEnabledTracks()
            self.log.info("library.orphans.hidden", ["count": hidden])
            return hidden
        } catch {
            self.log.warning("library.orphans.failed", ["error": String(reflecting: error)])
            return 0
        }
    }

    /// The stored path of each root, plus where its bookmark points now when
    /// that can be resolved. The scan walks the bookmark's target, so a root
    /// whose folder was renamed holds tracks under a path the row does not show.
    private func paths(of roots: [LibraryRoot]) -> [String] {
        roots.flatMap { root -> [String] in
            var isStale = false
            do {
                let resolved = try URL(
                    resolvingBookmarkData: root.bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return [root.path, resolved.path]
            } catch {
                // An unplugged drive: the stored path is all there is to go on.
                self.log.debug("library.root.bookmarkUnresolved", [
                    "path": root.path,
                    "error": String(reflecting: error),
                ])
                return [root.path]
            }
        }
    }
}

extension ScanProgress.Summary {
    /// This summary with `count` more tracks reported as removed.
    func addingRemoved(_ count: Int) -> ScanProgress.Summary {
        guard count > 0 else { return self }
        return ScanProgress.Summary(
            inserted: self.inserted,
            updated: self.updated,
            removed: self.removed + count,
            skipped: self.skipped,
            errors: self.errors,
            duration: self.duration
        )
    }
}

import Foundation
import Metadata
import Observability
import Persistence

// MARK: - FSEvents changes to existing paths

extension LibraryScanner {
    /// Handles a batch of FS-event URLs: filters to known audio extensions and
    /// triggers `scanSingleFile` for each matching, non-hidden file.
    ///
    /// When FSEvents reports a directory (e.g. when an entire folder is moved
    /// into a watched root) the event carries only the directory path, not one
    /// event per file inside it.  We recursively enumerate such directories so
    /// every audio file they contain is picked up automatically.
    ///
    /// An event for a path that no root holds is dropped. The watcher can
    /// follow more than the roots: the folder around a single-file root, and
    /// the parent of a root that is missing, which for a root at the top of a
    /// drive is the whole drive. Without the check every audio file changed
    /// there was imported, from folders the listener never added (#643).
    func handleFSChange(urls: [URL]) async {
        var didChange = false
        let trackRepo = TrackRepository(database: self.database)
        guard let coverage = await self.currentRootCoverage() else { return }
        for raw in urls {
            // NFC-normalise: APFS may deliver decomposed UTF-8.
            let url = URL(fileURLWithPath: raw.path.precomposedStringWithCanonicalMapping)
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            guard coverage.position(ofFileURL: url.absoluteString) == .inside else {
                self.log.debug("fsevents.outside_roots", ["path": url.lastPathComponent])
                continue
            }

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

            if !exists {
                if await self.handleRemovedPath(url, trackRepo: trackRepo) {
                    didChange = true
                }
            } else if isDir.boolValue {
                if await self.handleChangedDirectory(url, trackRepo: trackRepo) {
                    didChange = true
                }
            } else {
                if await self.handleChangedFile(url, trackRepo: trackRepo) {
                    didChange = true
                }
            }
        }
        if didChange, let callback = self.onFileImported {
            await callback()
        }
    }

    /// What the roots hold now, or `nil` when the roots cannot be read. Then
    /// nothing is known to be inside a root, so the batch is dropped; the next
    /// scan finds whatever it named.
    private func currentRootCoverage() async -> RootCoverage? {
        do {
            return try await RootCoverage(paths: self.paths(of: self.rootRepo.fetchAll()))
        } catch {
            self.log.warning("fsevents.rootsUnavailable", ["error": String(reflecting: error)])
            return nil
        }
    }

    /// A whole directory was moved/created: enumerate it recursively.
    ///
    /// - Returns: `true` when the library changed.
    func handleChangedDirectory(_ url: URL, trackRepo: TrackRepository) async -> Bool {
        var didChange = false
        let audioFiles = self.audioFiles(under: url)
        for fileURL in audioFiles {
            guard await self.contentChanged(url: fileURL, trackRepo: trackRepo) else { continue }
            do {
                _ = try await self.scanSingleFile(url: fileURL)
                self.log.debug("fsevents.file_rescanned", ["path": fileURL.lastPathComponent])
                didChange = true
            } catch {
                self.log.warning("fsevents.rescan_failed", ["path": fileURL.path, "error": "\(error)"])
            }
        }
        // ADR-087: the folder may have arrived with sidecar cues, and
        // the per-file cue event can fire before its audio is indexed;
        // running the attach after the folder's audio imports makes
        // a dropped-in single-file rip marker-complete either way.
        let service = CueMarkerService(
            trackRepo: trackRepo,
            markerRepo: TrackMarkerRepository(database: self.database)
        )
        for folder in ScanCoordinator.cueFolders(under: url) {
            let attached = await service.attachMarkers(inFolder: folder)
            if attached > 0 {
                didChange = true
            }
        }
        return didChange
    }

    /// Handles an event for one existing file: a cue sheet, a sidecar cover
    /// image or an audio file.
    ///
    /// - Returns: `true` when the library changed.
    func handleChangedFile(_ url: URL, trackRepo: TrackRepository) async -> Bool {
        var didChange = false
        if url.pathExtension.lowercased() == "cue" {
            // A cue appeared or changed: re-attach its folder's
            // markers (ADR-087). The audio around it is unchanged, so
            // the mtime guard below would skip everything; the marker
            // pass needs no track rescan at all.
            let service = CueMarkerService(
                trackRepo: trackRepo,
                markerRepo: TrackMarkerRepository(database: self.database)
            )
            let touched = await service.attachMarkers(inFolder: url.deletingLastPathComponent())
            if touched > 0 {
                self.log.debug("fsevents.cue_markers", ["path": url.lastPathComponent])
                didChange = true
            }
            return didChange
        }
        if SidecarArt.matches(url) {
            // A cover image appeared or changed. The audio around it
            // is unchanged (so the mtime guard below would skip it);
            // re-run one sibling through the importer, whose sidecar
            // fallback links the art to the folder's album (#388).
            if let sibling = self.audioFiles(under: url.deletingLastPathComponent()).first {
                do {
                    _ = try await self.scanSingleFile(url: sibling)
                    self.log.debug("fsevents.sidecar_art", ["path": url.lastPathComponent])
                    didChange = true
                } catch {
                    self.log.warning("fsevents.sidecar_failed", ["path": url.path, "error": "\(error)"])
                }
            }
            return didChange
        }
        guard TagReader.isSupported(url) else { return didChange }
        guard await self.contentChanged(url: url, trackRepo: trackRepo) else { return didChange }
        do {
            _ = try await self.scanSingleFile(url: url)
            self.log.debug("fsevents.file_rescanned", ["path": url.lastPathComponent])
            didChange = true
        } catch {
            self.log.warning("fsevents.rescan_failed", ["path": url.path, "error": "\(error)"])
        }
        return didChange
    }

    /// Returns all supported audio files found recursively under `directory`.
    ///
    /// Hidden files and hidden directories are skipped.
    func audioFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            guard TagReader.isSupported(fileURL) else { continue }
            results.append(fileURL)
        }
        return results
    }
}

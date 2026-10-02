import Foundation
import Metadata
import Observability
import Persistence

// MARK: - FSEvents changes to existing paths

extension LibraryScanner {
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

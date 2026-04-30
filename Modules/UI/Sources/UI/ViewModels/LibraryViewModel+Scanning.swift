import AppKit
import Library
import Observability
import Persistence
import UniformTypeIdentifiers

// MARK: - File-deletion injection

/// Abstraction over the two on-disk deletion modes used by ``LibraryViewModel``
/// when removing a track's backing file. Lives behind a protocol so tests can
/// inject failure modes (e.g. simulate `trashItem` failing on an external
/// volume) without touching the real file system.
public protocol TrackFileDeleter: Sendable {
    /// Move the file to the user's Trash. Throws on failure.
    func trash(_ url: URL) throws
    /// Permanently delete the file. Throws on failure.
    func remove(_ url: URL) throws
}

/// Default ``TrackFileDeleter`` backed by `FileManager.default`.
public struct SystemTrackFileDeleter: TrackFileDeleter {
    public init() {}
    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Result of ``LibraryViewModel/deleteTrackFromDisk(id:using:)``.
public enum DeleteFromDiskOutcome: Sendable {
    /// File was moved to Trash and the DB row soft-deleted.
    case trashed
    /// `trashItem` failed (external volume, permission denied, …). The DB row
    /// is unchanged. The caller should offer a "Delete Permanently"
    /// confirmation and, on confirm, call
    /// ``LibraryViewModel/permanentlyDeleteTrackFromDisk(id:using:)``.
    case trashFailed(error: any Error, fileURL: URL)
    /// Some other step failed (DB fetch, DB update, …). The DB row is
    /// unchanged and an error sheet has already been surfaced.
    case failed(error: any Error)
}

// MARK: - LibraryViewModel + Scanning

/// Scanning-related actions for ``LibraryViewModel``.
public extension LibraryViewModel {
    // MARK: - Library roots

    /// Loads the list of library root folders from the scanner.
    func refreshRoots() async {
        guard let scanner else { return }
        self.libraryRoots = await (try? scanner.roots()) ?? []
    }

    /// Opens an NSOpenPanel for the user to pick one or more folders.
    ///
    /// After the user confirms, each chosen folder is added as a library root
    /// and a scan is triggered.
    func addFolderByPicker() async {
        guard scanner != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose a folder containing music to add to your library."
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK else { return }
        await self.addURLs(panel.urls)
    }

    /// Opens an NSOpenPanel for the user to pick individual audio files.
    ///
    /// Each chosen file is added as its own library root so that only the
    /// selected file is indexed (not the whole folder).
    func addFilesByPicker() async {
        guard scanner != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.supportedAudioTypes
        panel.message = "Choose audio files to add to your library."
        panel.prompt = "Add Files"
        guard panel.runModal() == .OK else { return }
        // Add each file directly — the sandbox grants access to the selected URLs,
        // not their parent directories.
        await self.addURLs(panel.urls)
    }

    /// Handles a drag-and-drop of URLs onto the main window.
    ///
    /// Directories are added directly.  Audio files are added as individual roots
    /// so the sandbox grant for each file is preserved.
    func addDroppedURLs(_ urls: [URL]) async {
        guard scanner != nil else { return }
        await self.addURLs(urls)
    }

    /// Removes a library root by its database ID.
    ///
    /// Does not delete files from disk.
    func removeRoot(id: Int64) async {
        guard let scanner else { return }
        do {
            try await scanner.removeRoot(id: id)
            await self.refreshRoots()
            await self.tracks.load()
            await self.albums.load()
            await self.artists.load()
            await self.loadCurrentDestination()
        } catch {
            self.log.error("library.removeRoot.failed", ["error": String(reflecting: error)])
        }
    }

    /// Dismisses the finished scan summary banner.
    func dismissScanSummary() {
        self.scanSummary = nil
    }

    /// Starts or stops the FSEvents watcher based on the `library.watchForChanges` preference.
    func startOrStopWatcher() async {
        guard let scanner else { return }
        if UserDefaults.standard.bool(forKey: "library.watchForChanges") {
            // Reload all views whenever FSEvents picks up a new or changed file.
            await scanner.setOnFileImported { [weak self] in
                guard let self else { return }
                await self.tracks.load()
                await self.albums.load()
                await self.artists.load()
                await self.loadCurrentDestination()
            }
            await scanner.startWatching()
        } else {
            await scanner.setOnFileImported(nil)
            await scanner.stopWatching()
        }
    }

    /// Cancels any in-progress scan.
    func cancelScan() {
        self.scanTask?.cancel()
        self.scanTask = nil
        self.isScanning = false
        self.scanCurrentPath = ""
    }

    // MARK: - Internal

    internal static let supportedAudioTypes: [UTType] = [
        .audio,
        UTType("public.mp3") ?? .audio,
        UTType("public.aac-audio") ?? .audio,
        UTType("org.xiph.flac") ?? .audio,
        UTType("public.aifc-audio") ?? .audio,
        UTType("public.aiff-audio") ?? .audio,
    ]

    internal func addURLs(_ urls: [URL]) async {
        guard let scanner else { return }
        for url in urls {
            do {
                try await scanner.addRoot(url)
            } catch {
                self.log.error("library.addRoot.failed", ["url": url.path, "error": String(reflecting: error)])
            }
        }
        await self.refreshRoots()
        self.triggerScan()
    }

    internal func triggerScan() {
        self.triggerScan(mode: .quick)
    }

    /// Phase 3 audit M2: re-scan all library roots in either Quick or Full mode.
    /// Exposed for the File-menu "Quick Rescan" / "Full Rescan" commands.
    func rescanLibrary(mode: ScanMode) {
        self.triggerScan(mode: mode)
    }

    internal func triggerScan(mode: ScanMode) {
        guard let scanner else { return }
        guard !self.isScanning else { return }
        self.isScanning = true
        self.scanWalked = 0
        self.scanInserted = 0
        self.scanUpdated = 0
        self.scanCurrentPath = ""
        self.scanSummary = nil
        self.scanTask = Task { [weak self] in
            guard let self else { return }
            let stream = await scanner.scan(mode: mode)
            for await event in stream {
                self.handleScanEvent(event)
            }
            // Safety net: if the stream ends without a .finished event, reset state.
            if self.isScanning {
                self.isScanning = false
                self.scanCurrentPath = ""
            }
        }
    }

    internal func handleScanEvent(_ event: ScanProgress) {
        switch event {
        case .started:
            break

        case let .walking(path, walked):
            self.scanCurrentPath = URL(fileURLWithPath: path).lastPathComponent
            self.scanWalked = walked

        case let .processed(_, outcome):
            switch outcome {
            case .inserted:
                self.scanInserted += 1

            case .updated:
                self.scanUpdated += 1

            default:
                break
            }

        case let .finished(summary):
            self.scanSummary = summary
            self.isScanning = false
            self.scanCurrentPath = ""
            Task { [weak self] in
                guard let self else { return }
                // Reload all views — the user may have navigated away from Songs
                // before the scan completed, leaving Albums/Artists stale.
                await self.tracks.load()
                await self.albums.load()
                await self.artists.load()
                await self.refreshRoots()
                await self.startOrStopWatcher()
            }

        case .error, .removed:
            break
        }
    }

    // MARK: - Track management

    /// Soft-deletes `tracks` from the library (sets `disabled = true`).
    func removeTrack(id: Int64) async {
        let trackRepo = TrackRepository(database: self.database)
        do {
            var track = try await trackRepo.fetch(id: id)
            track.disabled = true
            try await trackRepo.update(track)
            await self.loadCurrentDestination()
            self.log.debug("library.removeTrack", ["id": id])
        } catch {
            self.log.error("library.removeTrack.failed", ["id": id, "error": String(reflecting: error)])
        }
    }

    /// Re-scans a single file to refresh its tags.
    ///
    /// Phase 5.5 audit M2: surfaces feedback. On success, shows an inline
    /// toast ("Re-scanned «Title»") for 2s. On failure, populates
    /// `rescanErrorMessage` so RootView can present a dedicated error sheet
    /// distinct from the playback-error alert.
    func rescanTrack(id: Int64) async {
        guard let scanner else { return }
        let trackRepo = TrackRepository(database: self.database)
        do {
            let track = try await trackRepo.fetch(id: id)
            guard let url = URL(string: track.fileURL) else {
                self.rescanErrorMessage = "Could not re-scan: the file path is invalid."
                return
            }
            _ = try await scanner.scanSingleFile(url: url)
            await self.tracks.load()
            self.log.debug("library.rescanTrack", ["id": id])
            let title = track.title ?? url.lastPathComponent
            self.showToast(ToastMessage(text: "Re-scanned “\(title)”", kind: .success))
        } catch {
            self.log.error("library.rescanTrack.failed", ["id": id, "error": String(reflecting: error)])
            self.rescanErrorMessage = "Could not re-scan the file: \(error.localizedDescription)"
        }
    }

    /// Moves a track's backing file to Trash and soft-deletes the library row.
    ///
    /// Returns an outcome so the caller can offer a secondary "Delete
    /// Permanently" confirmation when trashing fails (e.g. external volume,
    /// permission denied). On a trash failure the database row is **not**
    /// touched — the soft-delete only happens after the file has actually
    /// left its original location.
    @discardableResult
    func deleteTrackFromDisk(
        id: Int64,
        using fileOps: any TrackFileDeleter = SystemTrackFileDeleter()
    ) async -> DeleteFromDiskOutcome {
        let trackRepo = TrackRepository(database: self.database)
        do {
            var track = try await trackRepo.fetch(id: id)
            if let url = URL(string: track.fileURL) {
                do {
                    try fileOps.trash(url)
                } catch {
                    self.log.error(
                        "library.deleteFromDisk.trashFailed",
                        ["id": id, "error": String(reflecting: error)]
                    )
                    return .trashFailed(error: error, fileURL: url)
                }
            }
            track.disabled = true
            try await trackRepo.update(track)
            await self.tracks.load()
            self.log.debug("library.deleteFromDisk", ["id": id])
            return .trashed
        } catch {
            self.log.error("library.deleteFromDisk.failed", ["id": id, "error": String(reflecting: error)])
            self.playbackErrorMessage = "Could not delete the file from disk: \(error.localizedDescription)"
            return .failed(error: error)
        }
    }

    /// Permanently deletes a track's backing file (no Trash) and soft-deletes
    /// the library row. Used as the fallback after `deleteTrackFromDisk` reports
    /// a `.trashFailed` outcome and the user has explicitly confirmed permanent
    /// deletion. The DB row is only updated if the file removal succeeds.
    func permanentlyDeleteTrackFromDisk(
        id: Int64,
        using fileOps: any TrackFileDeleter = SystemTrackFileDeleter()
    ) async {
        let trackRepo = TrackRepository(database: self.database)
        do {
            var track = try await trackRepo.fetch(id: id)
            guard let url = URL(string: track.fileURL) else {
                self.playbackErrorMessage = "Could not delete: the file path is invalid."
                return
            }
            try fileOps.remove(url)
            track.disabled = true
            try await trackRepo.update(track)
            await self.tracks.load()
            self.log.debug("library.permanentlyDeleteFromDisk", ["id": id])
        } catch {
            self.log.error(
                "library.permanentlyDeleteFromDisk.failed",
                ["id": id, "error": String(reflecting: error)]
            )
            self.playbackErrorMessage = "Could not permanently delete the file: \(error.localizedDescription)"
        }
    }

    // MARK: - Album settings

    /// Toggles the `force_gapless` flag for an album.
    func setAlbumForceGapless(albumID: Int64, forced: Bool) async {
        do {
            try await self.albumRepo.setForceGapless(albumID: albumID, forced: forced)
            // Patch the in-memory record rather than reloading the whole albums array.
            // A full reload replaces the array reference which resets the implicit
            // NavigationStack in the detail column and causes the view to pop back to
            // the albums grid.
            self.albums.patch(albumID: albumID) { $0.forceGapless = forced }
            self.log.debug("library.setForceGapless", ["albumID": albumID, "forced": forced])
        } catch {
            self.log.error("library.setForceGapless.failed", ["albumID": albumID, "error": String(reflecting: error)])
        }
    }

    /// Toggles the `excluded_from_shuffle` flag for an album and all its tracks.
    func setAlbumExcludedFromShuffle(albumID: Int64, excluded: Bool) async {
        do {
            try await self.albumRepo.setExcludedFromShuffle(albumID: albumID, excluded: excluded)
            self.albums.patch(albumID: albumID) { $0.excludedFromShuffle = excluded }
            self.log.debug("library.setAlbumExcludedFromShuffle", ["albumID": albumID, "excluded": excluded])
        } catch {
            self.log.error("library.setAlbumExcludedFromShuffle.failed", ["albumID": albumID, "error": String(reflecting: error)])
        }
    }

    /// Toggles the `excluded_from_shuffle` flag for a single track.
    func setTrackExcludedFromShuffle(trackID: Int64, excluded: Bool) async {
        let trackRepo = TrackRepository(database: self.database)
        do {
            try await trackRepo.setExcludedFromShuffle(trackID: trackID, excluded: excluded)
            await self.tracks.load()
            self.log.debug("library.setTrackExcludedFromShuffle", ["trackID": trackID, "excluded": excluded])
        } catch {
            self.log.error("library.setTrackExcludedFromShuffle.failed", ["trackID": trackID, "error": String(reflecting: error)])
        }
    }
}

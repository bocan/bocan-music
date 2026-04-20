import AppKit
import Library
import Observability
import Persistence
import UniformTypeIdentifiers

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
        } catch {
            self.log.error("library.removeRoot.failed", ["error": String(reflecting: error)])
        }
    }

    /// Dismisses the finished scan summary banner.
    func dismissScanSummary() {
        self.scanSummary = nil
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
            let stream = await scanner.scan(mode: .quick)
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
            await self.tracks.load()
            self.log.debug("library.removeTrack", ["id": id])
        } catch {
            self.log.error("library.removeTrack.failed", ["id": id, "error": String(reflecting: error)])
        }
    }

    /// Re-scans a single file to refresh its tags.
    func rescanTrack(id: Int64) async {
        guard let scanner else { return }
        let trackRepo = TrackRepository(database: self.database)
        do {
            let track = try await trackRepo.fetch(id: id)
            guard let url = URL(string: track.fileURL) else { return }
            _ = try await scanner.scanSingleFile(url: url)
            await self.tracks.load()
            self.log.debug("library.rescanTrack", ["id": id])
        } catch {
            self.log.error("library.rescanTrack.failed", ["id": id, "error": String(reflecting: error)])
        }
    }

    /// Moves a track's backing file to Trash and soft-deletes the library row.
    func deleteTrackFromDisk(id: Int64) async {
        let trackRepo = TrackRepository(database: self.database)
        do {
            var track = try await trackRepo.fetch(id: id)
            if let url = URL(string: track.fileURL) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            track.disabled = true
            try await trackRepo.update(track)
            await self.tracks.load()
            self.log.debug("library.deleteFromDisk", ["id": id])
        } catch {
            self.log.error("library.deleteFromDisk.failed", ["id": id, "error": String(reflecting: error)])
        }
    }

    // MARK: - Album settings

    /// Toggles the `force_gapless` flag for an album.
    func setAlbumForceGapless(albumID: Int64, forced: Bool) async {
        do {
            try await self.albumRepo.setForceGapless(albumID: albumID, forced: forced)
            await self.albums.load()
            self.log.debug("library.setForceGapless", ["albumID": albumID, "forced": forced])
        } catch {
            self.log.error("library.setForceGapless.failed", ["albumID": albumID, "error": String(reflecting: error)])
        }
    }

    /// Toggles the `excluded_from_shuffle` flag for an album and all its tracks.
    func setAlbumExcludedFromShuffle(albumID: Int64, excluded: Bool) async {
        do {
            try await self.albumRepo.setExcludedFromShuffle(albumID: albumID, excluded: excluded)
            await self.albums.load()
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

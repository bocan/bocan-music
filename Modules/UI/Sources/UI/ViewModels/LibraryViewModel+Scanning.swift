import AppKit
import Library
import Observability
import Persistence
import UniformTypeIdentifiers

// MARK: - LibraryViewModel + Scanning

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
}

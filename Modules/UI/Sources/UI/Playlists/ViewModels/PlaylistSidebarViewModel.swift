import AppKit
import Foundation
import Library
import Observability
import Persistence

// MARK: - PlaylistSidebarViewModel

/// Drives the playlist section of the sidebar.  Owns a snapshot of the
/// folder tree and publishes changes as mutations complete.
@MainActor
public final class PlaylistSidebarViewModel: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var nodes: [PlaylistNode] = []
    @Published public var expandedFolders: Set<Int64> = []
    @Published public var renameTarget: PlaylistNode?
    @Published public var deleteTarget: PlaylistNode?
    @Published public var deleteRecursiveTarget: PlaylistNode?
    @Published public var newPlaylistParent: Int64?
    @Published public private(set) var pendingTrackIDs: [Int64] = []
    @Published public var isPresentingNewPlaylist = false
    @Published public var isPresentingNewFolder = false
    @Published public var isPresentingNewSmartPlaylist = false
    @Published public var lastError: String?
    /// Set to trigger the accent-colour picker sheet for a specific playlist.
    @Published public var accentColorTarget: PlaylistNode?

    // MARK: - Dependencies

    public let service: PlaylistService
    private let log = AppLogger.make(.ui)

    /// Called after one or more playlists/folders are successfully deleted.
    /// The set contains all deleted IDs (the target plus any recursive descendants).
    /// Wire this up externally (e.g. in `LibraryViewModel`) to deselect the content pane.
    public var onDidDelete: ((Set<Int64>) -> Void)?

    /// Invoked when the user picks "Export…" from a manual playlist's
    /// context menu. Wire this in `LibraryViewModel` to drive the export sheet.
    public var onRequestExport: ((Int64, String) -> Void)?

    // MARK: - Init

    public init(service: PlaylistService) {
        self.service = service
    }

    // MARK: - Public API

    /// Reloads the sidebar tree.
    public func reload() async {
        do {
            self.nodes = try await self.service.list()
        } catch {
            self.log.error("playlist.sidebar.reload.failed", ["error": String(reflecting: error)])
            self.lastError = "Could not load playlists."
        }
    }

    public func toggle(folderID: Int64) {
        if self.expandedFolders.contains(folderID) {
            self.expandedFolders.remove(folderID)
        } else {
            self.expandedFolders.insert(folderID)
        }
    }

    /// Expands a folder without toggling it closed if it is already open.
    public func expand(folderID: Int64) {
        self.expandedFolders.insert(folderID)
    }

    /// Moves a playlist by ID into a folder (or top-level when `folderID` is `nil`).
    ///
    /// Convenience overload used by drag-and-drop, which only has the payload ID
    /// rather than the full `PlaylistNode`.
    public func move(playlistID: Int64, toFolder folderID: Int64?) async {
        do {
            try await self.service.move(playlistID, toParent: folderID)
            await self.reload()
        } catch {
            self.lastError = self.describe(error)
        }
    }

    public func beginNewPlaylist(parent: Int64? = nil, trackIDs: [Int64] = []) {
        self.log.debug("playlist.sheet", ["kind": "playlist", "parent": parent ?? -1])
        self.newPlaylistParent = parent
        self.pendingTrackIDs = trackIDs
        self.isPresentingNewPlaylist = true
    }

    public func beginNewFolder(parent: Int64? = nil) {
        self.log.debug("playlist.sheet", ["kind": "folder", "parent": parent ?? -1])
        self.newPlaylistParent = parent
        self.isPresentingNewFolder = true
    }

    public func beginNewSmartPlaylist() {
        self.log.debug("playlist.sheet", ["kind": "smart"])
        self.newPlaylistParent = nil
        self.isPresentingNewSmartPlaylist = true
    }

    public func createPlaylist(name: String) async -> Int64? {
        do {
            let playlist = try await self.service.create(name: name, parentID: self.newPlaylistParent)
            let ids = self.pendingTrackIDs
            self.pendingTrackIDs = []
            if !ids.isEmpty, let playlistID = playlist.id {
                try await self.service.addTracks(ids, to: playlistID)
            }
            await self.reload()
            return playlist.id
        } catch {
            self.lastError = self.describe(error)
            return nil
        }
    }

    public func createFolder(name: String) async -> Int64? {
        do {
            let f = try await self.service.createFolder(name: name, parentID: self.newPlaylistParent)
            await self.reload()
            return f.id
        } catch {
            self.lastError = self.describe(error)
            return nil
        }
    }

    public func rename(_ node: PlaylistNode, to newName: String) async {
        do {
            try await self.service.rename(node.id, to: newName)
            await self.reload()
        } catch {
            self.lastError = self.describe(error)
        }
    }

    public func delete(_ node: PlaylistNode, recursive: Bool = false) async {
        // Collect all IDs that will be deleted *before* the operation so the
        // callback can clear any active selection for deleted playlists.
        let deletedIDs: Set<Int64> = recursive
            ? Self.allIDs(in: [node])
            : [node.id]
        do {
            if recursive {
                try await self.service.deleteRecursively(node.id)
            } else {
                try await self.service.delete(node.id)
            }
            await self.reload()
            // Defer to the next main-actor tick: if onDidDelete swaps the
            // content pane (e.g. smart playlist → songs) while the confirmation
            // sheet is still animating closed, SwiftUI's dialog bridge can
            // crash mid-layout (EXC_BAD_ACCESS in UC::DriverCore).
            Task { @MainActor [weak self] in
                self?.onDidDelete?(deletedIDs)
            }
        } catch {
            self.lastError = self.describe(error)
        }
    }

    public func duplicate(_ node: PlaylistNode) async -> Int64? {
        do {
            let copy = try await self.service.duplicate(node.id)
            await self.reload()
            return copy.id
        } catch {
            self.lastError = self.describe(error)
            return nil
        }
    }

    public func move(_ node: PlaylistNode, toParent parent: Int64?) async {
        do {
            try await self.service.move(node.id, toParent: parent)
            await self.reload()
        } catch {
            self.lastError = self.describe(error)
        }
    }

    public func addTracks(_ trackIDs: [Int64], to playlistID: Int64) async {
        do {
            try await self.service.addTracks(trackIDs, to: playlistID)
            await self.reload()
        } catch {
            self.lastError = self.describe(error)
        }
    }

    /// Sorts the contents of `node` by `key` and reloads the sidebar.
    public func sortContents(_ node: PlaylistNode, by key: PlaylistSortKey) async {
        do {
            try await self.service.sortContents(node.id, by: key)
            await self.reload()
        } catch {
            self.lastError = self.describe(error)
        }
    }

    // MARK: - Cover art & accent colour

    /// Opens a non-blocking `NSOpenPanel` for the user to pick a cover image,
    /// copies it into Application Support, and persists the path via the service.
    ///
    /// Uses `NSOpenPanel.begin(completionHandler:)` (not `runModal`) so the
    /// audio render callback is never starved — see Phase 5.5 audit issue #28.
    public func setCoverArt(for node: PlaylistNode) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to use as the cover art for \"\(node.name)\"."
        panel.prompt = "Set Cover Art"

        let response = await Self.openPanelAsync(panel)
        guard response == .OK, let url = panel.url else { return }

        self.log.debug("playlist.setCoverArt.begin", ["id": node.id])
        do {
            let destPath = try await Self.saveImageFile(url: url, playlistID: node.id)
            try await self.service.setCoverArtPath(node.id, path: destPath)
            await self.reload()
            self.log.debug("playlist.setCoverArt.done", ["id": node.id, "path": destPath])
        } catch {
            self.log.error("playlist.setCoverArt.failed", ["error": String(reflecting: error)])
            self.lastError = "Could not set cover art."
        }
    }

    /// Persists `hex` (or `nil` to clear) as the accent colour for `id`.
    public func setAccentColor(_ hex: String?, for id: Int64) async {
        do {
            try await self.service.setAccentColor(id, hex: hex)
            await self.reload()
        } catch {
            self.log.error("playlist.setAccentColor.failed", ["error": String(reflecting: error)])
            self.lastError = "Could not update accent colour."
        }
    }

    // MARK: - Private: file helpers

    /// Copies the image at `url` into the per-playlist-covers directory and
    /// returns its new absolute path.  Converts non-JPEG formats to JPEG @90%.
    private nonisolated static func saveImageFile(url: URL, playlistID: Int64) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let raw = try Data(contentsOf: url)
                    let dir = Self.playlistCoversDirectory()
                    try FileManager.default.createDirectory(
                        at: dir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    let stamp = Int64(Date().timeIntervalSince1970)
                    let filename = "playlist_\(playlistID)_\(stamp).jpg"
                    let dest = dir.appendingPathComponent(filename)
                    let jpeg = Self.normaliseToJPEG(raw) ?? raw
                    try jpeg.write(to: dest, options: .atomic)
                    continuation.resume(returning: dest.path)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// `~/Library/Application Support/Bocan/playlist_covers/`
    private nonisolated static func playlistCoversDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Bocan/playlist_covers", isDirectory: true)
    }

    /// Converts arbitrary image data to JPEG @90% quality.  Returns `nil` if
    /// the input is already a JPEG or the conversion fails.
    private nonisolated static func normaliseToJPEG(_ data: Data) -> Data? {
        // JPEG magic bytes: FF D8 FF
        if data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF]) { return nil }
        guard let img = NSImage(data: data) else { return nil }
        var rect = NSRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let bmp = NSBitmapImageRep(cgImage: cg)
        // swiftlint:disable:next legacy_objc_type
        let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: NSNumber(value: 0.90)]
        return bmp.representation(using: .jpeg, properties: props)
    }

    /// Async wrapper around `NSOpenPanel.begin(completionHandler:)`.
    /// Does NOT spin a modal run loop — safe to call during active playback.
    private static func openPanelAsync(
        _ panel: NSOpenPanel
    ) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { (c: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { response in c.resume(returning: response) }
        }
    }

    // MARK: - Helpers

    /// Returns `true` when `node` is visible given the current expansion state.
    public func isVisible(_ node: PlaylistNode) -> Bool {
        // Walk the tree finding the node and checking all its ancestors are expanded.
        self.isVisible(node.id, in: self.nodes, ancestorsExpanded: true)
    }

    private func isVisible(_ id: Int64, in nodes: [PlaylistNode], ancestorsExpanded: Bool) -> Bool {
        for node in nodes {
            if node.id == id { return ancestorsExpanded }
            let nextExpanded = ancestorsExpanded && self.expandedFolders.contains(node.id)
            if self.isVisible(id, in: node.children, ancestorsExpanded: nextExpanded) {
                return true
            }
        }
        return false
    }

    /// Flattens visible nodes in depth-first render order with an accompanying depth.
    public func flattened() -> [(node: PlaylistNode, depth: Int)] {
        var result: [(node: PlaylistNode, depth: Int)] = []
        self.appendFlattened(self.nodes, depth: 0, into: &result)
        return result
    }

    private func appendFlattened(
        _ nodes: [PlaylistNode],
        depth: Int,
        into result: inout [(node: PlaylistNode, depth: Int)]
    ) {
        for node in nodes {
            result.append((node, depth))
            if node.kind == .folder, self.expandedFolders.contains(node.id) {
                self.appendFlattened(node.children, depth: depth + 1, into: &result)
            }
        }
    }

    /// Returns a flat list of all folder nodes in tree order, for the Move to Folder menu.
    public func allFolders() -> [PlaylistNode] {
        var result: [PlaylistNode] = []
        self.collectFolders(self.nodes, into: &result)
        return result
    }

    /// Returns the node with the given `id` from the full tree, or `nil` if not found.
    public func findNode(id: Int64) -> PlaylistNode? {
        Self.findNode(id: id, in: self.nodes)
    }

    private static func findNode(id: Int64, in nodes: [PlaylistNode]) -> PlaylistNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = findNode(id: id, in: node.children) { return found }
        }
        return nil
    }

    private func collectFolders(_ nodes: [PlaylistNode], into result: inout [PlaylistNode]) {
        for node in nodes where node.kind == .folder {
            result.append(node)
            self.collectFolders(node.children, into: &result)
        }
    }

    private func describe(_ error: Error) -> String {
        if let pe = error as? PlaylistError {
            return String(describing: pe)
        }
        return error.localizedDescription
    }

    /// Returns the IDs of `nodes` and all their descendants.
    private static func allIDs(in nodes: [PlaylistNode]) -> Set<Int64> {
        var ids = Set<Int64>()
        for node in nodes {
            ids.insert(node.id)
            ids.formUnion(self.allIDs(in: node.children))
        }
        return ids
    }
}

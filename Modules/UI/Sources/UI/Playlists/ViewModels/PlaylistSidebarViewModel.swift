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
    @Published public var isPresentingNewPlaylist = false
    @Published public var isPresentingNewFolder = false
    @Published public var isPresentingNewSmartPlaylist = false
    @Published public var lastError: String?

    // MARK: - Dependencies

    public let service: PlaylistService
    private let log = AppLogger.make(.ui)

    /// Called after one or more playlists/folders are successfully deleted.
    /// The set contains all deleted IDs (the target plus any recursive descendants).
    /// Wire this up externally (e.g. in `LibraryViewModel`) to deselect the content pane.
    public var onDidDelete: ((Set<Int64>) -> Void)?

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

    public func beginNewPlaylist(parent: Int64? = nil) {
        self.log.debug("playlist.sheet", ["kind": "playlist", "parent": parent ?? -1])
        self.newPlaylistParent = parent
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
            self.onDidDelete?(deletedIDs)
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

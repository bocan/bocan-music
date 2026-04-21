import Foundation
import Persistence

/// A playlist (or folder) node as surfaced to the UI.
///
/// `PlaylistService.list()` assembles these into a forest rooted at
/// nodes whose `parentID` is `nil`. Folders hold `children`; manual and
/// smart playlists have `children == []` by convention.
public struct PlaylistNode: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let kind: PlaylistKind
    public let parentID: Int64?
    public let coverArtPath: String?
    public let accentHex: String?
    public let trackCount: Int
    public let totalDuration: TimeInterval
    public let sortOrder: Int?
    public let children: [PlaylistNode]

    public init(
        id: Int64,
        name: String,
        kind: PlaylistKind,
        parentID: Int64?,
        coverArtPath: String?,
        accentHex: String?,
        trackCount: Int,
        totalDuration: TimeInterval,
        sortOrder: Int?,
        children: [PlaylistNode]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.coverArtPath = coverArtPath
        self.accentHex = accentHex
        self.trackCount = trackCount
        self.totalDuration = totalDuration
        self.sortOrder = sortOrder
        self.children = children
    }
}

/// Flattens and re-assembles playlist hierarchies.
///
/// Pure value transformations; no database access. `PlaylistService`
/// fetches flat playlist rows plus per-id counts/durations and hands
/// them to `buildTree` to produce a UI-ready forest.
public enum PlaylistFolderTree {
    /// Input row describing a single playlist for tree assembly.
    public struct Row: Sendable, Hashable {
        public let id: Int64
        public let name: String
        public let kind: PlaylistKind
        public let parentID: Int64?
        public let coverArtPath: String?
        public let accentHex: String?
        public let trackCount: Int
        public let totalDuration: TimeInterval
        public let sortOrder: Int?

        public init(
            id: Int64,
            name: String,
            kind: PlaylistKind,
            parentID: Int64?,
            coverArtPath: String?,
            accentHex: String?,
            trackCount: Int,
            totalDuration: TimeInterval,
            sortOrder: Int?
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.parentID = parentID
            self.coverArtPath = coverArtPath
            self.accentHex = accentHex
            self.trackCount = trackCount
            self.totalDuration = totalDuration
            self.sortOrder = sortOrder
        }
    }

    /// Builds a forest of `PlaylistNode`s from a flat list of `rows`.
    ///
    /// Rows whose `parentID` is absent from the input become roots,
    /// not orphans (this keeps the tree well-formed even if the
    /// database is in an in-progress state).
    public static func buildTree(from rows: [Row]) -> [PlaylistNode] {
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var childrenOf: [Int64: [Row]] = [:]
        var roots: [Row] = []
        for row in rows {
            if let parent = row.parentID, byID[parent] != nil {
                childrenOf[parent, default: []].append(row)
            } else {
                roots.append(row)
            }
        }
        func sortChildren(_ list: [Row]) -> [Row] {
            list.sorted {
                let lhs = $0.sortOrder ?? Int.max
                let rhs = $1.sortOrder ?? Int.max
                if lhs != rhs { return lhs < rhs }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        func build(_ row: Row) -> PlaylistNode {
            let rawChildren = childrenOf[row.id] ?? []
            let nested = sortChildren(rawChildren).map(build)
            return PlaylistNode(
                id: row.id,
                name: row.name,
                kind: row.kind,
                parentID: row.parentID,
                coverArtPath: row.coverArtPath,
                accentHex: row.accentHex,
                trackCount: row.trackCount,
                totalDuration: row.totalDuration,
                sortOrder: row.sortOrder,
                children: nested
            )
        }
        return sortChildren(roots).map(build)
    }

    /// Returns `true` when attaching `candidateID` under `newParentID` would
    /// introduce a cycle — that is, if `newParentID` is `candidateID` itself
    /// or appears among `candidateID`'s descendants in `rows`.
    public static func wouldCreateCycle(
        candidateID: Int64,
        newParentID: Int64?,
        rows: [Row]
    ) -> Bool {
        guard let newParentID else { return false }
        if newParentID == candidateID { return true }
        var childrenOf: [Int64: [Int64]] = [:]
        for row in rows {
            if let parent = row.parentID {
                childrenOf[parent, default: []].append(row.id)
            }
        }
        var stack: [Int64] = [candidateID]
        var seen: Set<Int64> = []
        while let current = stack.popLast() {
            if seen.insert(current).inserted == false { continue }
            if current == newParentID { return true }
            for child in childrenOf[current] ?? [] {
                stack.append(child)
            }
        }
        return false
    }

    /// Returns every descendant `id` of `rootID` (excluding `rootID`).
    public static func descendantIDs(of rootID: Int64, rows: [Row]) -> [Int64] {
        var childrenOf: [Int64: [Int64]] = [:]
        for row in rows {
            if let parent = row.parentID {
                childrenOf[parent, default: []].append(row.id)
            }
        }
        var out: [Int64] = []
        var stack: [Int64] = childrenOf[rootID] ?? []
        while let current = stack.popLast() {
            out.append(current)
            stack.append(contentsOf: childrenOf[current] ?? [])
        }
        return out
    }
}

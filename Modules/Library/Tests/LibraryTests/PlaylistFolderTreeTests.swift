import Foundation
import Testing
@testable import Library
@testable import Persistence

@Suite("PlaylistFolderTree")
struct PlaylistFolderTreeTests {
    private func row(
        id: Int64,
        name: String = "",
        kind: PlaylistKind = .manual,
        parent: Int64? = nil,
        sortOrder: Int? = nil
    ) -> PlaylistFolderTree.Row {
        PlaylistFolderTree.Row(
            id: id,
            name: name.isEmpty ? "p\(id)" : name,
            kind: kind,
            parentID: parent,
            coverArtPath: nil,
            accentHex: nil,
            trackCount: 0,
            totalDuration: 0,
            sortOrder: sortOrder
        )
    }

    @Test("buildTree returns an empty forest for an empty input")
    func buildEmpty() {
        #expect(PlaylistFolderTree.buildTree(from: []).isEmpty)
    }

    @Test("buildTree groups children under their folder parent")
    func buildBasic() {
        let rows = [
            self.row(id: 1, kind: .folder),
            self.row(id: 2, parent: 1),
            self.row(id: 3, parent: 1),
            self.row(id: 4),
        ]
        let tree = PlaylistFolderTree.buildTree(from: rows)
        #expect(tree.count == 2)
        let folder = tree.first { $0.id == 1 }
        #expect(folder?.children.map(\.id).sorted() == [2, 3])
        #expect(tree.contains { $0.id == 4 })
    }

    @Test("buildTree promotes rows with missing parents to roots")
    func buildMissingParent() {
        let rows = [
            self.row(id: 2, parent: 99),
        ]
        let tree = PlaylistFolderTree.buildTree(from: rows)
        #expect(tree.count == 1)
        #expect(tree.first?.id == 2)
    }

    @Test("wouldCreateCycle detects self-parenting")
    func cycleSelf() {
        let rows = [self.row(id: 1, kind: .folder)]
        #expect(PlaylistFolderTree.wouldCreateCycle(candidateID: 1, newParentID: 1, rows: rows))
    }

    @Test("wouldCreateCycle detects descendant-parenting")
    func cycleDescendant() {
        // 1 contains 2 contains 3; moving 1 under 3 must be rejected.
        let rows = [
            self.row(id: 1, kind: .folder),
            self.row(id: 2, kind: .folder, parent: 1),
            self.row(id: 3, kind: .folder, parent: 2),
        ]
        #expect(PlaylistFolderTree.wouldCreateCycle(candidateID: 1, newParentID: 3, rows: rows))
    }

    @Test("wouldCreateCycle allows moving to root")
    func cycleAllowRoot() {
        let rows = [
            self.row(id: 1, kind: .folder),
            self.row(id: 2, parent: 1),
        ]
        #expect(
            PlaylistFolderTree.wouldCreateCycle(candidateID: 2, newParentID: nil, rows: rows) == false
        )
    }

    @Test("descendantIDs walks the tree")
    func descendants() {
        let rows = [
            self.row(id: 1, kind: .folder),
            self.row(id: 2, kind: .folder, parent: 1),
            self.row(id: 3, parent: 2),
            self.row(id: 4, parent: 1),
        ]
        let desc = PlaylistFolderTree.descendantIDs(of: 1, rows: rows).sorted()
        #expect(desc == [2, 3, 4])
    }
}

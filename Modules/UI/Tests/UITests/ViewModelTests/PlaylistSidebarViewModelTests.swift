import Foundation
import Library
import Persistence
import Testing
@testable import UI

// MARK: - PlaylistSidebarViewModelTests

@Suite("PlaylistSidebarViewModel")
@MainActor
struct PlaylistSidebarViewModelTests {
    private func makeVM() async throws -> (PlaylistSidebarViewModel, PlaylistService) {
        let db = try await Database(location: .inMemory)
        let service = PlaylistService(database: db)
        return (PlaylistSidebarViewModel(service: service), service)
    }

    @Test("reload populates an empty sidebar")
    func reloadEmpty() async throws {
        let (vm, _) = try await self.makeVM()
        await vm.reload()
        #expect(vm.nodes.isEmpty)
    }

    @Test("concurrent reloads coalesce without corrupting state")
    func concurrentReloadsCoalesce() async throws {
        let (vm, service) = try await self.makeVM()
        _ = try await service.create(name: "A", parentID: nil)
        // Three overlapping reloads (as at launch) must leave a correct, fully
        // loaded tree -- the coalescer must not deadlock or drop the result.
        async let r1: Void = vm.reload()
        async let r2: Void = vm.reload()
        async let r3: Void = vm.reload()
        _ = await (r1, r2, r3)
        #expect(vm.isLoaded)
        #expect(vm.nodes.contains { $0.name == "A" })
    }

    @Test("createPlaylist adds a node")
    func createPlaylist() async throws {
        let (vm, _) = try await self.makeVM()
        let id = await vm.createPlaylist(name: "Road Trip")
        #expect(id != nil)
        #expect(vm.nodes.contains { $0.name == "Road Trip" })
    }

    @Test("createFolder adds a folder node")
    func createFolder() async throws {
        let (vm, _) = try await self.makeVM()
        let id = await vm.createFolder(name: "Listening")
        #expect(id != nil)
        #expect(vm.nodes.first { $0.id == id }?.kind == .folder)
    }

    @Test("toggle flips expansion state")
    func toggleExpansion() async throws {
        let (vm, _) = try await self.makeVM()
        vm.toggle(folderID: 42)
        #expect(vm.expandedFolders.contains(42))
        vm.toggle(folderID: 42)
        #expect(vm.expandedFolders.contains(42) == false)
    }

    @Test("flattened respects folder expansion")
    func flattenedExpansion() async throws {
        let (vm, service) = try await self.makeVM()
        let folder = try await service.createFolder(name: "F")
        guard let fid = folder.id else { return }
        _ = try await service.create(name: "Child", parentID: fid)
        await vm.reload()
        // Collapsed by default: only folder visible at top level.
        let collapsed = vm.flattened()
        #expect(collapsed.count == 1)
        vm.toggle(folderID: fid)
        let expanded = vm.flattened()
        #expect(expanded.count == 2)
        #expect(expanded.map(\.depth) == [0, 1])
    }

    @Test("rename updates the node")
    func rename() async throws {
        let (vm, _) = try await self.makeVM()
        _ = await vm.createPlaylist(name: "Old")
        guard let node = vm.nodes.first else { return }
        await vm.rename(node, to: "New")
        #expect(vm.nodes.contains { $0.name == "New" })
    }

    @Test("delete removes the node")
    func deleteNode() async throws {
        let (vm, _) = try await self.makeVM()
        _ = await vm.createPlaylist(name: "P")
        guard let node = vm.nodes.first else { return }
        await vm.delete(node)
        #expect(vm.nodes.isEmpty)
    }

    @Test("duplicate appends a copy")
    func duplicate() async throws {
        let (vm, _) = try await self.makeVM()
        _ = await vm.createPlaylist(name: "Alpha")
        guard let node = vm.nodes.first else { return }
        _ = await vm.duplicate(node)
        let names = vm.nodes.map(\.name).sorted()
        #expect(names == ["Alpha", "Alpha copy"])
    }

    @Test("errors are surfaced as lastError")
    func errorSurface() async throws {
        let (vm, _) = try await self.makeVM()
        _ = await vm.createPlaylist(name: "   ")
        #expect(vm.lastError != nil)
    }

    // MARK: - Naming happens once

    @Test("a created playlist is not reopened for renaming")
    func createLeavesRenameAlone() async throws {
        let (vm, _) = try await self.makeVM()
        _ = await vm.createPlaylist(name: "Road Trip")
        // The name came from the sheet; asking for it again in the sidebar row
        // reads as though the first answer was not taken.
        #expect(vm.renamingPlaylistID == nil)
    }

    @Test("a created folder is not reopened for renaming either")
    func createFolderLeavesRenameAlone() async throws {
        let (vm, _) = try await self.makeVM()
        _ = await vm.createFolder(name: "Listening")
        #expect(vm.renamingPlaylistID == nil)
    }

    @Test("renaming is still available on demand")
    func inlineRenameStillWorks() async throws {
        let (vm, _) = try await self.makeVM()
        _ = await vm.createPlaylist(name: "Road Trip")
        let node = try #require(vm.nodes.first)
        vm.beginInlineRename(node)
        #expect(vm.renamingPlaylistID == node.id)
    }

    // MARK: - Counts follow the tracks

    @Test("adding tracks through the view model refreshes the sidebar count")
    func addTracksRefreshesCount() async throws {
        let db = try await Database(location: .inMemory)
        let service = PlaylistService(database: db)
        let vm = PlaylistSidebarViewModel(service: service)
        let repo = TrackRepository(database: db)
        var trackIDs: [Int64] = []
        for index in 0 ..< 3 {
            let now = Int64(Date().timeIntervalSince1970)
            let track = Track(
                fileURL: "file:///tmp/count\(index).mp3",
                fileSize: 1024,
                fileMtime: now,
                fileFormat: "mp3",
                duration: 120,
                title: "Count \(index)",
                addedAt: now,
                updatedAt: now
            )
            try await trackIDs.append(repo.insert(track))
        }
        let playlist = try await service.create(name: "Road Trip", parentID: nil)
        let playlistID = try #require(playlist.id)
        await vm.reload()
        try #require(vm.nodes.first?.trackCount == 0)

        await vm.addTracks(trackIDs, to: playlistID)

        #expect(vm.nodes.first?.trackCount == 3, "the badge next to the playlist reads this")
    }
}

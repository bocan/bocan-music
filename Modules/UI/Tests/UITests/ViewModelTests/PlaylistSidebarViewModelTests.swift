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
}

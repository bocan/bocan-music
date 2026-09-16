import AppKit
import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - RestoredSortChainTests (ADR-093 slice 3)

/// A restored sort is one column and one direction, which is all the user ever
/// chose. Applying it bare left every tie to the sort algorithm until the next
/// header click, so a relaunch did not look like the click that set it.
@Suite("A restored sort keeps its chain")
@MainActor
struct RestoredSortChainTests {
    private func makeVM() async throws -> TracksViewModel {
        let db = try await Database(location: .inMemory)
        return TracksViewModel(
            repository: TrackRepository(database: db),
            artistRepository: ArtistRepository(database: db),
            albumRepository: AlbumRepository(database: db)
        )
    }

    private func keys(_ vm: TracksViewModel) -> [String] {
        vm.sortOrder.compactMap { TrackTable.sortKey(for: $0) }
    }

    @Test("restoring Artist gives the same chain a click would")
    func restoringArtistComposes() async throws {
        let vm = try await self.makeVM()
        vm.setSort(column: .artist, ascending: true)
        #expect(self.keys(vm) == ["artistName", "albumName", "discNumber", "trackNumber"])
    }

    @Test("restoring Album gives its own chain, artist before disc and track")
    func restoringAlbumComposes() async throws {
        let vm = try await self.makeVM()
        vm.setSort(column: .album, ascending: true)
        #expect(self.keys(vm) == ["albumName", "artistName", "discNumber", "trackNumber"])
    }

    @Test("a descending restore keeps its direction, and the tie-breakers stay ascending")
    func descendingRestoreKeepsDirection() async throws {
        let vm = try await self.makeVM()
        vm.setSort(column: .playCount, ascending: false)

        #expect(self.keys(vm).first == "playCount")
        #expect(vm.sortOrder.first?.order == .reverse)
        let ascendingTieBreakers = vm.sortOrder.dropFirst().filter { $0.order == .forward }
        #expect(ascendingTieBreakers.count == vm.sortOrder.count - 1)
    }

    @Test("the chain never outgrows the cap")
    func restoredChainIsCapped() async throws {
        let vm = try await self.makeVM()
        for column in [TrackSortColumn.genre, .year, .title, .artist, .album] {
            vm.setSort(column: column, ascending: true)
            #expect(vm.sortOrder.count <= TrackTable.maxSortKeys)
            #expect(!vm.sortOrder.isEmpty)
        }
    }

    @Test("a column the chain cannot name still sorts by itself")
    func unmappableColumnStillSorts() async throws {
        let vm = try await self.makeVM()
        // Whatever the column list holds, a restore must never leave the table
        // unsorted just because a chain could not be composed for it.
        for column in TrackSortColumn.allCases {
            vm.setSort(column: column, ascending: true)
            #expect(!vm.sortOrder.isEmpty, "\(column) restored to an empty sort")
        }
    }
}

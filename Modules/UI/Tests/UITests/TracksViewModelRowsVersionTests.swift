import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - TracksViewModelRowsVersionTests

/// #450 slice 2: `TracksViewModel.rowsVersion` is what lets `TrackTable` skip
/// its per-row walks. It must move on every write to `rows`, including the
/// in-place single-row rewrite, and stay put for everything else.
@Suite("TracksViewModel rows version")
@MainActor
struct TracksViewModelRowsVersionTests {
    private func makeVM() async throws -> TracksViewModel {
        let db = try await Database(location: .inMemory)
        return TracksViewModel(
            repository: TrackRepository(database: db),
            artistRepository: ArtistRepository(database: db),
            albumRepository: AlbumRepository(database: db)
        )
    }

    private func makeTrack(id: Int64, title: String, playCount: Int = 0) -> Track {
        var track = Track(
            fileURL: "file:///tmp/\(title).flac",
            fileSize: 1024,
            fileMtime: 0,
            fileFormat: "flac",
            duration: 180,
            title: title,
            addedAt: 0,
            updatedAt: 0
        )
        track.id = id
        track.playCount = playCount
        return track
    }

    @Test("setTracks moves the version once")
    func setTracksBumps() async throws {
        let vm = try await makeVM()
        let before = vm.rowsVersion

        vm.setTracks([self.makeTrack(id: 1, title: "A"), self.makeTrack(id: 2, title: "B")])

        #expect(vm.rows.count == 2)
        #expect(vm.rowsVersion == before + 1)
    }

    @Test("an in-place single-row update moves the version, and a no-match update does not")
    func updateRowsBumpsOnlyWhenARowChanges() async throws {
        let vm = try await makeVM()
        vm.setTracks([self.makeTrack(id: 1, title: "A"), self.makeTrack(id: 2, title: "B")])
        let before = vm.rowsVersion

        vm.updateRows(for: [self.makeTrack(id: 2, title: "B", playCount: 5)])
        #expect(vm.rows.first { $0.id == 2 }?.track.playCount == 5)
        #expect(vm.rowsVersion > before, "the table must learn about a play-count bump")

        let afterMatch = vm.rowsVersion
        vm.updateRows(for: [self.makeTrack(id: 99, title: "not here")])
        #expect(vm.rowsVersion == afterMatch, "a track outside the list touches no row")
    }

    @Test("selection changes leave the version alone")
    func selectionDoesNotBump() async throws {
        let vm = try await makeVM()
        vm.setTracks([self.makeTrack(id: 1, title: "A")])
        let before = vm.rowsVersion

        vm.selection = [1]
        vm.selection = []

        #expect(vm.rowsVersion == before)
    }
}

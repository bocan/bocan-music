import Foundation
import Library
import Testing
@testable import Persistence
@testable import UI

// MARK: - MockCoverArtFetcher

/// Stub conformer used to verify DI without hitting the network.
private final class MockCoverArtFetcher: CoverArtFetcher, @unchecked Sendable {
    var stubbedCandidates: [CoverArtCandidate] = []
    var stubbedImageData = Data([0xFF, 0xD8, 0xFF]) // minimal JPEG header
    private(set) var searchCallCount = 0
    private(set) var lastSearchArtist: String?
    private(set) var lastSearchAlbum: String?

    func search(artist: String, album: String) async throws -> [CoverArtCandidate] {
        self.searchCallCount += 1
        self.lastSearchArtist = artist
        self.lastSearchAlbum = album
        return self.stubbedCandidates
    }

    func image(for candidate: CoverArtCandidate, size: CoverArtSize) async throws -> Data {
        self.stubbedImageData
    }
}

// MARK: - TagEditorViewModelCoverArtTests

@Suite("TagEditorViewModel cover art DI")
@MainActor
struct TagEditorViewModelCoverArtTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeCandidate(id: String = "c1") -> CoverArtCandidate {
        // swiftlint:disable:next force_unwrapping
        let url = URL(string: "https://example.com/art.jpg")!
        return CoverArtCandidate(
            id: id,
            title: "Abbey Road",
            artist: "The Beatles",
            thumbnailURL: url,
            fullURL: url,
            source: .musicbrainz
        )
    }

    @Test("coverArtFetchVM is created with the injected fetcher")
    func coverArtFetchVMUsesInjectedFetcher() async throws {
        let db = try await makeDatabase()
        let svc = try MetadataEditService(database: db)
        let mock = MockCoverArtFetcher()
        mock.stubbedCandidates = [self.makeCandidate()]
        let vm = TagEditorViewModel(service: svc, trackIDs: [], fetcher: mock)

        vm.coverArtFetchVM.searchArtist = "The Beatles"
        vm.coverArtFetchVM.searchAlbum = "Abbey Road"
        vm.coverArtFetchVM.search()

        // Allow the Task inside search() to run.
        try await Task.sleep(for: .milliseconds(100))

        #expect(mock.searchCallCount == 1)
        #expect(mock.lastSearchArtist == "The Beatles")
        #expect(mock.lastSearchAlbum == "Abbey Road")
        #expect(vm.coverArtFetchVM.candidates.count == 1)
        #expect(vm.coverArtFetchVM.candidates.first?.id == "c1")
    }

    @Test("default init has a coverArtFetchVM with no pending search")
    func defaultInitHasCoverArtFetchVM() async throws {
        let db = try await makeDatabase()
        let svc = try MetadataEditService(database: db)
        let vm = TagEditorViewModel(service: svc, trackIDs: [])
        // Verify the vm holds a coverArtFetchVM without triggering network.
        #expect(vm.coverArtFetchVM.candidates.isEmpty)
        #expect(!vm.coverArtFetchVM.isSearching)
    }
}

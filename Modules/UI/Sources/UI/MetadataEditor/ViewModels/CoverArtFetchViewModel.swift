import Foundation
import Library
import Observability
import SwiftUI

// MARK: - CoverArtFetchViewModel

/// Drives the cover-art fetch sheet.
///
/// Searches MusicBrainz / Cover Art Archive and loads thumbnail images
/// for display in the picker grid.
@MainActor
public final class CoverArtFetchViewModel: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var candidates: [CoverArtCandidate] = []
    @Published public private(set) var thumbnails: [String: Data] = [:]
    @Published public private(set) var isSearching = false
    @Published public var searchArtist = ""
    @Published public var searchAlbum = ""
    @Published public var selectedCandidateID: String?
    @Published public var lastError: String?

    // MARK: - Dependencies

    private let fetcher: any CoverArtFetcher
    private let log = AppLogger.make(.ui)
    private var searchTask: Task<Void, Never>?

    // MARK: - Init

    public init(fetcher: any CoverArtFetcher, prefilledArtist: String = "", prefilledAlbum: String = "") {
        self.fetcher = fetcher
        self.searchArtist = prefilledArtist
        self.searchAlbum = prefilledAlbum
    }

    // MARK: - Public API

    /// Triggers a cover art search with the current `searchArtist` / `searchAlbum`.
    public func search() {
        self.searchTask?.cancel()
        self.isSearching = true
        self.lastError = nil
        self.candidates = []
        self.thumbnails = [:]

        self.searchTask = Task {
            defer { self.isSearching = false }
            do {
                let results = try await self.fetcher.search(
                    artist: self.searchArtist,
                    album: self.searchAlbum
                )
                guard !Task.isCancelled else { return }
                self.candidates = results
                self.log.debug("coverart.fetch.done", ["count": results.count])

                // Load thumbnails concurrently (up to 5 at a time)
                await withTaskGroup(of: (String, Data?).self) { group in
                    for candidate in results.prefix(10) {
                        group.addTask {
                            let data = try? await self.fetcher.image(
                                for: candidate,
                                size: .thumbnail
                            )
                            return (candidate.id, data)
                        }
                    }
                    for await (id, data) in group {
                        if let thumb = data { self.thumbnails[id] = thumb }
                    }
                }
            } catch is CancellationError {
                // Normal — user triggered a new search
            } catch {
                self.lastError = "Search failed: \(error.localizedDescription)"
                self.log.error("coverart.fetch.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Downloads the full-resolution image for `candidateID` and returns the data.
    public func fullImage(for candidateID: String) async throws -> Data {
        guard let candidate = self.candidates.first(where: { $0.id == candidateID }) else {
            throw URLError(.fileDoesNotExist)
        }
        return try await self.fetcher.image(for: candidate, size: .full)
    }
}

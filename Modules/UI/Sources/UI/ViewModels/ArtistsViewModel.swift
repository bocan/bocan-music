import Foundation
import Observability
import Persistence

// MARK: - ArtistsViewModel

/// Manages the sorted list of artists shown in `ArtistsView`.
@MainActor
public final class ArtistsViewModel: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var artists: [Artist] = []
    @Published public private(set) var isLoading = false
    @Published public var selectedArtistID: Int64?

    // MARK: - Internal

    private let repository: ArtistRepository
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(repository: ArtistRepository) {
        self.repository = repository
    }

    // MARK: - Public API

    /// Loads all artists sorted alphabetically by sort name.
    public func load() async {
        self.isLoading = true
        self.log.debug("artists.load.start", [:])
        do {
            self.artists = try await self.repository.fetchAll()
            self.log.debug("artists.load.end", ["count": self.artists.count])
        } catch {
            self.log.error("artists.load.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Replaces the artist list with a pre-fetched result (search results).
    public func setArtists(_ items: [Artist]) {
        self.artists = items
    }
}

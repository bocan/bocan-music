/// How far the one-off MusicBrainz artist lookup pass (#401) has got, for
/// the scan banner: artists already looked up against all artists that carry
/// a MusicBrainz id. Artists without an id are never looked up and count
/// toward neither.
public struct ArtistEnrichmentProgress: Equatable, Sendable {
    /// Artists with an id and a `musicbrainz_fetched_at` stamp.
    public let fetched: Int
    /// All artists with a MusicBrainz id.
    public let total: Int

    public init(fetched: Int, total: Int) {
        self.fetched = fetched
        self.total = total
    }

    /// Artists still waiting for a lookup.
    public var remaining: Int {
        max(0, self.total - self.fetched)
    }

    /// True once every artist with an id has been looked up (or there are none).
    public var isComplete: Bool {
        self.remaining == 0
    }
}

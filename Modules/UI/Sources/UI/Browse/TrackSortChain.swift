import AppKit

// MARK: - TrackSortChain

/// The tie-breakers that sit behind a clicked column (ADR-093).
///
/// Sorting by one column alone leaves every tie to whatever order the sort
/// algorithm happens to produce, which for a stat column like Play Count means
/// equal counts scattered in import order. A chain of tie-breakers makes the
/// result readable: the same play count, grouped by artist and album.
///
/// The table has thirty sortable columns, so this is a default plus a short
/// list of exceptions rather than a chain per column. Almost every column
/// wants the same tie-breakers, because the question a listener asks of a
/// sorted column is "whose is it, and from what".
@MainActor
enum TrackSortChain {
    /// What almost every column gets behind it: whose it is, from what, in
    /// disc and track order.
    ///
    /// Disc and track travel together and in that order. Track without disc
    /// misorders a multi-disc album, putting disc two's track one ahead of
    /// disc one's track two; disc without track sorts nothing anybody can see.
    /// Splitting the pair is what made the Genre and Year chains read as
    /// nonsense when the cap cut them off after disc.
    static let globalTieBreakers = ["artistName", "albumName", "discNumber", "trackNumber"]

    /// The columns whose tie-breakers differ from the global chain.
    ///
    /// Most columns need no entry. The dedupe in
    /// `TrackTable.constrainedChain(from:)` drops the clicked key when the
    /// chain proposes it again, so Artist already yields artist, album, disc,
    /// track from the global list alone. Genre and Year need no entry either:
    /// the global list behind them is exactly right, genre then artist, album,
    /// disc and track.
    static let overrides: [String: [String]] = [
        // Finding a song by name: group the matches by who recorded them.
        // No disc or track, because a title sort is not an album reading.
        "title": ["artistName", "albumName"],
        // Artist comes before disc and track because the album column is a
        // title, not an identity: "16 Biggest Hits" is three different albums
        // by Willie Nelson, Alabama and Alan Jackson, and with artist last
        // they interleaved by track number. The cost is a true compilation,
        // whose tracks carry different artists and so group by artist rather
        // than keeping the album's running order; there is no album-artist on
        // the row to separate the two cases.
        "albumName": ["artistName", "discNumber", "trackNumber"],
    ]

    /// The tie-breakers for `sortKey`, which is a sort-descriptor key as
    /// `TrackTable.comparator(from:)` understands it.
    static func tieBreakers(after sortKey: String) -> [String] {
        self.overrides[sortKey] ?? self.globalTieBreakers
    }

    /// The full chain for a clicked column: the column itself, then its
    /// tie-breakers behind it.
    ///
    /// Tie-breakers are always ascending, whatever direction the clicked
    /// column carries: sorting play count descending still wants artists A to
    /// Z underneath, or every group reads backwards.
    ///
    /// The result is deduped and capped by `TrackTable.constrainedChain`, so
    /// the clicked column always leads even when the chain proposes it again,
    /// and the chain cannot outgrow what a reader can follow.
    static func compose(clicked: NSSortDescriptor) -> [NSSortDescriptor] {
        guard let clickedKey = clicked.key else { return [] }
        let behind = self.tieBreakers(after: clickedKey).map {
            NSSortDescriptor(key: $0, ascending: true)
        }
        return TrackTable.constrainedChain(from: [clicked] + behind)
    }
}

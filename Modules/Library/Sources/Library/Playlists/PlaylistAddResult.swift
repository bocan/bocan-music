// MARK: - PlaylistAddResult

/// What ``PlaylistService/addTracks(_:to:at:)`` did with the songs it was
/// given.
///
/// A playlist holds each song once, so `skipped` counts the songs that were
/// already in it, or repeated within the batch. The UI turns a non-zero count
/// into a message, so an add that does nothing is never silent (#720).
public struct PlaylistAddResult: Sendable, Equatable {
    /// Songs written to the playlist.
    public let added: Int
    /// Songs left out because the playlist already holds them.
    public let skipped: Int

    public init(added: Int, skipped: Int) {
        self.added = added
        self.skipped = skipped
    }

    /// The songs in `trackIDs` that the playlist does not hold yet, in their
    /// order, each at most once.
    static func newMembers(_ trackIDs: [Int64], existing: [Int64]) -> [Int64] {
        var seen = Set(existing)
        return trackIDs.filter { seen.insert($0).inserted }
    }
}

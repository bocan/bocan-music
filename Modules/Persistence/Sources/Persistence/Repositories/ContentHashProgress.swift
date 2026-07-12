/// Content-hash backfill progress over the hashable library (enabled,
/// whole-file tracks with a bookmark). Phone Sync can only serve a track once
/// its whole-file hash exists, so `ready`/`total` is exactly "how much of the
/// library a paired phone can see".
public struct ContentHashProgress: Equatable, Sendable {
    /// Hashable tracks still waiting for a content hash.
    public let missing: Int
    /// All hashable tracks.
    public let total: Int

    public init(missing: Int, total: Int) {
        self.missing = missing
        self.total = total
    }

    /// Hashable tracks already carrying a hash.
    public var ready: Int {
        self.total - self.missing
    }

    public var isComplete: Bool {
        self.missing == 0
    }
}

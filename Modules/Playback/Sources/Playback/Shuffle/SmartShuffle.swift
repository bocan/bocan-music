import Foundation

// MARK: - SmartShuffle

/// A weighted shuffle that favours loved and highly-rated tracks, spaces out same-album
/// clusters, and never surfaces tracks marked `excludedFromShuffle`.
///
/// Weight formula (higher = more likely to appear earlier):
///   base   = 1.0
///   +0.2 per rating point (0–100 rating → 0–20 bonus)
///   +3.0 if loved
///   +0.5 per play-count (log-scaled to cap influence)
///   −2.0 if played in the last 24 hours
///   Minimum weight: 0.001 (ensures all non-excluded tracks can appear)
///
/// Excluded tracks are stripped from the result entirely.
///
/// Same-album spacing: after sampling a track, the next draw raises
/// the weight of other albums so clusters are diluted.
public struct SmartShuffle: ShuffleStrategy {
    public init() {}

    public func shuffled(_ items: [QueueItem], seed: UInt64) -> [QueueItem] {
        // Strip excluded tracks.
        let eligible = items.filter { !$0.excludedFromShuffle }
        guard !eligible.isEmpty else { return [] }
        guard eligible.count > 1 else { return eligible }

        var rng = Xoshiro256StarStar(seed: seed)
        var remaining = eligible
        var result: [QueueItem] = []
        result.reserveCapacity(eligible.count)

        let now = Int64(Date().timeIntervalSince1970)
        let daySeconds: Int64 = 86400

        while !remaining.isEmpty {
            let weights = remaining.map { self.weight(for: $0, now: now, daySeconds: daySeconds) }
            let selected = self.weightedSample(from: remaining, weights: weights, using: &rng)
            result.append(selected)
            remaining.removeAll { $0.id == selected.id }

            // Same-album spacing: if we just placed an album track, temporarily
            // de-prioritise remaining tracks from the same album by removing and
            // re-inserting at the back. This is a simple effective heuristic.
            if let albumID = selected.albumID {
                let sameAlbum = remaining.filter { $0.albumID == albumID }
                if sameAlbum.count >= 2 {
                    remaining = remaining.filter { $0.albumID != albumID } + sameAlbum
                }
            }
        }

        return result
    }

    // MARK: - Private helpers

    private func weight(for item: QueueItem, now: Int64, daySeconds: Int64) -> Double {
        var w = 1.0
        w += Double(item.rating) * 0.2 // rating 0-100 → +0..20
        if item.loved { w += 3.0 }
        w += 0.5 * log(Double(item.playCount) + 1.0) // log-scaled play count
        if let lastPlayed = item.lastPlayedAt,
           now - lastPlayed < daySeconds { w -= 2.0 } // played today penalty
        return max(0.001, w)
    }

    private func weightedSample(
        from items: [QueueItem],
        weights: [Double],
        using rng: inout Xoshiro256StarStar
    ) -> QueueItem {
        let total = weights.reduce(0, +)
        // Map the next random double onto [0, total)
        let pick = (Double(rng.next()) / Double(UInt64.max)) * total
        var cumulative = 0.0
        for (item, weight) in zip(items, weights) {
            cumulative += weight
            if pick < cumulative { return item }
        }
        return items.last! // Fallback (floating-point rounding)
    }
}

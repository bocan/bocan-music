import Foundation

/// Sparse integer position arithmetic for `playlist_tracks`.
///
/// Positions are integers spaced by `step` (default 1024) so that middle
/// inserts pick the midpoint between neighbours without renumbering the
/// whole playlist. When an adjacent gap collapses to ≤ 1, `needsRepack`
/// flips to `true` and callers should apply a fresh `repack` before
/// writing.
///
/// This is a pure-value helper — no database, no I/O. It is tested as
/// a standalone module so the algebra stays correct independent of GRDB.
public enum PositionArranger {
    /// Default spacing between positions.
    public static let step = 1024

    /// Position returned when inserting into an empty playlist.
    public static let firstPosition = 1024

    // MARK: - Insert

    /// Returns the position to use when appending a new row after `existing`.
    public static func appendPosition(after existing: [Int]) -> Int {
        (existing.max() ?? 0) + self.step
    }

    /// Returns the position to use when inserting a new row at `index`
    /// within a playlist whose current positions (in order) are `existing`.
    ///
    /// - Parameters:
    ///   - index: destination index, clamped to `0...existing.count`.
    ///   - existing: the ordered list of current positions.
    public static func insertPosition(at index: Int, in existing: [Int]) -> Int {
        let sorted = existing
        let clamped = max(0, min(index, sorted.count))
        if sorted.isEmpty {
            return self.firstPosition
        }
        if clamped == 0 {
            // Insert at start. Use first/2 if there is headroom, else a step below.
            let first = sorted[0]
            return first > self.step ? first - self.step : first / 2
        }
        if clamped == sorted.count {
            return sorted[sorted.count - 1] + self.step
        }
        let prev = sorted[clamped - 1]
        let next = sorted[clamped]
        return (prev + next) / 2
    }

    /// Returns positions for a block of `count` rows inserted at `index`.
    ///
    /// Positions are spread evenly across the gap between neighbours so
    /// subsequent middle-inserts still have room. Falls back to a repack
    /// signal when the gap is too tight to fit `count + 1` integers.
    public static func insertPositions(
        count: Int,
        at index: Int,
        in existing: [Int]
    ) -> (positions: [Int], needsRepack: Bool) {
        precondition(count >= 0)
        guard count > 0 else { return ([], false) }
        let sorted = existing
        let clamped = max(0, min(index, sorted.count))

        if sorted.isEmpty {
            return ((0 ..< count).map { self.firstPosition + $0 * self.step }, false)
        }

        if clamped == sorted.count {
            let base = sorted[sorted.count - 1]
            return ((1 ... count).map { base + $0 * self.step }, false)
        }

        if clamped == 0 {
            let first = sorted[0]
            // Want positions p_1 < p_2 < … < p_count < first
            // Keep at least 1-unit gap on either side.
            let available = first - 1
            if available >= count {
                // Evenly spread with at least 1 between each and before first.
                let gap = max(1, available / (count + 1))
                let positions = (1 ... count).map { gap * $0 }
                let needsRepack = positions.last ?? 0 >= first || (positions.last ?? 0) + 1 >= first
                return (positions, needsRepack || gap <= 1)
            }
            // No room — still produce monotonic positions; caller must repack first.
            return ((0 ..< count).map { -count + $0 }, true)
        }

        let prev = sorted[clamped - 1]
        let next = sorted[clamped]
        let gap = next - prev
        // We need `count + 1` integer slots (prev, x1, …, xN, next). Require gap > count.
        if gap > count + 1 {
            let slice = gap / (count + 1)
            let positions = (1 ... count).map { prev + slice * $0 }
            return (positions, slice <= 1)
        }
        // Gap too tight: emit intermediate positions anyway (caller will see
        // needsRepack and rewrite). Use simple arithmetic progression between
        // prev + 1 and next - 1; may collide with `next` when gap <= count,
        // so we force a repack signal.
        let positions = (1 ... count).map { prev + $0 }
        return (positions, true)
    }

    // MARK: - Repack

    /// Returns positions spaced at `step` starting from `step`.
    public static func repackedPositions(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return (1 ... count).map { $0 * self.step }
    }

    /// Returns `true` when any adjacent gap in `positions` is `<= 1`.
    public static func needsRepack(_ positions: [Int]) -> Bool {
        guard positions.count >= 2 else { return false }
        for i in 1 ..< positions.count where positions[i] - positions[i - 1] <= 1 {
            return true
        }
        return false
    }

    // MARK: - Move (SwiftUI parity)

    /// Applies `move(fromOffsets:toOffset:)` semantics to `items` and returns
    /// the resulting order.
    ///
    /// Mirrors `Array.move(fromOffsets:toOffset:)` so call-sites that build
    /// on a SwiftUI `List.onMove` can route straight through this helper
    /// without worrying about SwiftUI's slightly quirky index semantics
    /// (the `toOffset` is the index in the *original* array).
    public static func applyMove<T>(_ items: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T] {
        // SwiftUI's Array.move(fromOffsets:toOffset:) is defined in SwiftUI.
        // Reproduce its semantics here so this helper stays free of UI deps:
        //   1. Pull elements at `source` (in original order).
        //   2. Compute the destination after accounting for removals below it.
        //   3. Insert the pulled block at the adjusted destination.
        guard !source.isEmpty, !items.isEmpty else { return items }
        let orderedSource = source.sorted()
        let pulled = orderedSource.compactMap { $0 < items.count ? items[$0] : nil }
        let removalsBefore = orderedSource.count(where: { $0 < destination })
        var remaining = items
        for index in orderedSource.reversed() where index < remaining.count {
            remaining.remove(at: index)
        }
        let adjustedDestination = max(0, min(remaining.count, destination - removalsBefore))
        remaining.insert(contentsOf: pulled, at: adjustedDestination)
        return remaining
    }
}

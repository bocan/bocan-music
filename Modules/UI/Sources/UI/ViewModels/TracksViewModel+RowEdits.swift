import Persistence

// MARK: - TracksViewModel + row edits

/// The pure half of the two in-place row edits: swapping rows for refreshed
/// copies (`updateRows(for:)`) and dropping deleted rows (`removeRows(ids:)`).
/// Both return `nil` when no row matched, so the caller leaves the stored array
/// and its version alone, and both build one new array instead of writing
/// `rows` per match: `rows` has a `didSet` that bumps `rowsVersion`, and the
/// table does a full per-row walk for every bump (#453).
extension TracksViewModel {
    /// Returns `rows` with every row whose track id appears in `newRowsByID`
    /// swapped for the new value.
    static func replacing(_ rows: [TrackRow], with newRowsByID: [Int64: TrackRow]) -> [TrackRow]? {
        var rows = rows
        var changed = false
        for i in rows.indices {
            if let id = rows[i].track.id, let updated = newRowsByID[id] {
                rows[i] = updated
                changed = true
            }
        }
        return changed ? rows : nil
    }

    /// Returns `rows` without the rows whose track id is in `ids`. A row with
    /// no id cannot be one of them, so it stays.
    static func removing(_ ids: Set<Int64>, from rows: [TrackRow]) -> [TrackRow]? {
        let remaining = rows.filter { row in
            row.track.id.map { !ids.contains($0) } ?? true
        }
        return remaining.count == rows.count ? nil : remaining
    }
}

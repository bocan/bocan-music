import Persistence

// MARK: - TrackTableUpdatePlan

/// The decision half of `TrackTable.updateNSView` (#450): which of the table's
/// inputs changed since the last apply, and therefore which per-row work is
/// owed. SwiftUI calls `updateNSView` whenever the parent re-renders, whether
/// or not the table's inputs moved, and with 14,000 rows every unconditional
/// walk (the content diff, the rows dictionary, the selection index set) was a
/// visible hitch. The rows version gates all of them: an update whose inputs
/// are unchanged does nothing per row. Pure, so it is unit-tested host-less.
struct TrackTableUpdatePlan: Equatable {
    /// What the coordinator remembers from the last apply.
    struct Applied: Equatable {
        /// `nil` until the first apply.
        var rowsVersion: Int?
        var ids: [Int64] = []
        /// `Track.ID` is `Int64?`, so this is a double optional: outer `nil`
        /// means "never applied", inner `nil` means "nothing playing".
        var nowPlayingID: Track.ID?
        var selection: Set<Track.ID>?
    }

    enum RowsWork: Equatable {
        /// The rows version is unchanged: no walk, no dictionary rebuild.
        case unchanged
        /// Same ID set under a new version: diff content and reload changed rows.
        case reconfigure
        /// A different ID set: apply a new snapshot.
        case structural
    }

    var rowsWork: RowsWork
    /// The ID list computed for this update; only present when the rows changed.
    var ids: [Int64]?
    /// Rows to reload because the now-playing highlight moved while the rows
    /// did not; `reconfigure` covers the highlight itself.
    var highlightReload: [Int64]
    /// The selection index set walk is owed only when the rows or the
    /// selection changed since the last apply.
    var syncSelection: Bool

    /// - Parameter ids: the current row IDs, computed only when the rows
    ///   version moved (a compactMap over every row).
    static func make(
        rowsVersion: Int,
        ids: () -> [Int64],
        nowPlayingID: Track.ID?,
        selection: Set<Track.ID>,
        applied: Applied
    ) -> Self {
        let rowsChanged = applied.rowsVersion != rowsVersion
        var plan = Self(rowsWork: .unchanged, ids: nil, highlightReload: [], syncSelection: false)
        if rowsChanged {
            let newIDs = ids()
            plan.ids = newIDs
            plan.rowsWork = newIDs == applied.ids ? .reconfigure : .structural
        } else if applied.nowPlayingID != nowPlayingID {
            plan.highlightReload = [applied.nowPlayingID, nowPlayingID].compactMap { $0.flatMap(\.self) }
        }
        plan.syncSelection = rowsChanged || applied.selection != selection
        return plan
    }

    /// The memory to keep once this plan has been applied.
    func applied(
        after previous: Applied,
        rowsVersion: Int,
        nowPlayingID: Track.ID?,
        selection: Set<Track.ID>
    ) -> Applied {
        Applied(
            rowsVersion: rowsVersion,
            ids: self.ids ?? previous.ids,
            nowPlayingID: nowPlayingID,
            selection: selection
        )
    }
}

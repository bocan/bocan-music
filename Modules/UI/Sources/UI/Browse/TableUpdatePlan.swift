import Persistence

// MARK: - TableUpdatePlan

/// The decision half of a diffable table's `updateNSView` (#450): which of the
/// table's inputs changed since the last apply, and therefore which per-row
/// work is owed. SwiftUI calls `updateNSView` whenever the parent re-renders,
/// whether or not the table's inputs moved, and with 14,000 rows every
/// unconditional walk (the content diff, the rows dictionary, the selection
/// index set) was a visible hitch. The rows version gates all of them: an
/// update whose inputs are unchanged does nothing per row. Pure, so it is
/// unit-tested host-less.
///
/// Generic over the row ID and the selection's element type so the local
/// library's `TrackTable` (`Int64` rows, a `Track.ID` selection) and the
/// Subsonic `SubsonicSongTable` (`String` rows, no selection input) share one
/// helper and one set of tests (#455).
struct TableUpdatePlan<ID: Hashable, SelectionID: Hashable>: Equatable {
    /// What the coordinator remembers from the last apply.
    struct Applied: Equatable {
        /// `nil` until the first apply.
        var rowsVersion: Int?
        var ids: [ID] = []
        /// `nil` means nothing playing. Never-applied is `rowsVersion == nil`.
        var nowPlayingID: ID?
        var selection: Set<SelectionID>?
    }

    enum RowsWork: Equatable {
        /// The rows version is unchanged: no walk, no dictionary rebuild.
        case unchanged
        /// Same ID list under a new version: diff content and reload changed rows.
        case reconfigure
        /// A different ID list: apply a new snapshot.
        case structural
    }

    var rowsWork: RowsWork
    /// The ID list computed for this update; only present when the rows changed.
    var ids: [ID]?
    /// Rows to reload because the now-playing highlight moved while the rows
    /// did not; `reconfigure` covers the highlight itself.
    var highlightReload: [ID]
    /// The selection index set walk is owed only when the rows or the
    /// selection changed since the last apply.
    var syncSelection: Bool

    /// - Parameter ids: the current row IDs, computed only when the rows
    ///   version moved (a walk over every row).
    static func make(
        rowsVersion: Int,
        ids: () -> [ID],
        nowPlayingID: ID?,
        selection: Set<SelectionID>,
        applied: Applied
    ) -> Self {
        let rowsChanged = applied.rowsVersion != rowsVersion
        var plan = Self(rowsWork: .unchanged, ids: nil, highlightReload: [], syncSelection: false)
        if rowsChanged {
            let newIDs = ids()
            plan.ids = newIDs
            plan.rowsWork = newIDs == applied.ids ? .reconfigure : .structural
        } else if applied.nowPlayingID != nowPlayingID {
            plan.highlightReload = [applied.nowPlayingID, nowPlayingID].compactMap(\.self)
        }
        plan.syncSelection = rowsChanged || applied.selection != selection
        return plan
    }

    /// The memory to keep once this plan has been applied.
    func applied(
        after previous: Applied,
        rowsVersion: Int,
        nowPlayingID: ID? = nil,
        selection: Set<SelectionID> = []
    ) -> Applied {
        Applied(
            rowsVersion: rowsVersion,
            ids: self.ids ?? previous.ids,
            nowPlayingID: nowPlayingID,
            selection: selection
        )
    }
}

/// The local library's table keys rows by `Track.ID`'s wrapped `Int64`; its
/// SwiftUI selection is a `Set<Track.ID>`, so the two types differ.
typealias TrackTableUpdatePlan = TableUpdatePlan<Int64, Track.ID>

/// The Subsonic table keys rows by the per-server row identifier string and
/// has no selection input.
typealias SubsonicSongTableUpdatePlan = TableUpdatePlan<String, String>

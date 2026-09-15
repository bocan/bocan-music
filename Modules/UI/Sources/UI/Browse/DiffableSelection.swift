import AppKit

// MARK: - Diffable apply that keeps the selection

/// Applies `snapshot` and puts the table's selection back where it was.
///
/// A snapshot carrying reloaded items clears the whole table selection when it
/// is applied. Measured on macOS 26: select row 2 of five, reload any item, and
/// `selectedRowIndexes` comes back empty, whether or not the reloaded row is
/// the selected one. `NSTableView.reloadData(forRowIndexes:)` does not do this,
/// but the diffable data source owns the rows, so the snapshot is the route.
///
/// The symptom was a row losing its own blue highlight the instant it started
/// playing: double-clicking a song reloads that row to move the now-playing
/// mark onto it, which dropped the selection, and nothing put it back until the
/// next reload the play counter happened to trigger, up to a couple of seconds
/// later.
///
/// Reloading never reorders rows, so the indexes that were selected before the
/// apply are still the right ones after it.
///
/// - Parameter whileSyncing: called with `true` before the selection is put
///   back and `false` after, so a coordinator can suppress the
///   selection-did-change notification the restore would otherwise publish.
@MainActor
func applyPreservingSelection<Section: Hashable & Sendable, Item: Hashable & Sendable>(
    _ snapshot: NSDiffableDataSourceSnapshot<Section, Item>,
    to dataSource: NSTableViewDiffableDataSource<Section, Item>,
    in tableView: NSTableView?,
    whileSyncing: (Bool) -> Void = { _ in }
) {
    let selected = tableView?.selectedRowIndexes
    dataSource.apply(snapshot, animatingDifferences: false)
    guard let tableView,
          let selected,
          !selected.isEmpty,
          tableView.selectedRowIndexes != selected else { return }
    whileSyncing(true)
    tableView.selectRowIndexes(selected, byExtendingSelection: false)
    whileSyncing(false)
}

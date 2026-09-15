import AppKit
import Testing
@testable import UI

// MARK: - DiffableSelectionTests

/// A double-clicked row used to lose its own blue highlight the moment it
/// started playing: moving the now-playing mark reloads that row, and applying
/// a snapshot with reloaded items clears the table's selection.
@Suite("Diffable reload keeps the selection")
@MainActor
struct DiffableSelectionTests {
    private func makeTable() -> (NSTableView, NSTableViewDiffableDataSource<Int, Int64>) {
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        let dataSource = NSTableViewDiffableDataSource<Int, Int64>(tableView: tableView) { _, _, _, _ in
            NSTableCellView()
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int64>()
        snapshot.appendSections([0])
        snapshot.appendItems([10, 20, 30, 40, 50])
        dataSource.apply(snapshot, animatingDifferences: false)
        tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        return (tableView, dataSource)
    }

    @Test("a plain apply of a reloaded item clears the selection, which is why the helper exists")
    func plainApplyLosesTheSelection() {
        let (tableView, dataSource) = self.makeTable()
        try? #require(tableView.selectedRowIndexes == IndexSet(integer: 2))

        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([30])
        dataSource.apply(snapshot, animatingDifferences: false)

        #expect(
            tableView.selectedRowIndexes.isEmpty,
            "AppKit stopped clearing the selection on an applied reload; the helper can go"
        )
    }

    @Test("the helper puts the selection back when the reloaded row is the selected one")
    func helperRestoresSelectedRow() {
        let (tableView, dataSource) = self.makeTable()
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([30])
        applyPreservingSelection(snapshot, to: dataSource, in: tableView)
        #expect(tableView.selectedRowIndexes == IndexSet(integer: 2))
    }

    @Test("and when some other row is reloaded")
    func helperRestoresAfterUnrelatedReload() {
        let (tableView, dataSource) = self.makeTable()
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([10])
        applyPreservingSelection(snapshot, to: dataSource, in: tableView)
        #expect(tableView.selectedRowIndexes == IndexSet(integer: 2))
    }

    @Test("a multi-row selection survives too")
    func helperRestoresMultipleRows() {
        let (tableView, dataSource) = self.makeTable()
        let wanted = IndexSet([1, 3])
        tableView.selectRowIndexes(wanted, byExtendingSelection: false)
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([20, 40])
        applyPreservingSelection(snapshot, to: dataSource, in: tableView)
        #expect(tableView.selectedRowIndexes == wanted)
    }

    @Test("the restore is announced so a coordinator can hold its own notification")
    func helperReportsSyncing() {
        let (tableView, dataSource) = self.makeTable()
        var flags: [Bool] = []
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([30])
        applyPreservingSelection(snapshot, to: dataSource, in: tableView) { flags.append($0) }
        #expect(flags == [true, false])
    }

    @Test("nothing selected, nothing to restore, nothing announced")
    func emptySelectionIsLeftAlone() {
        let (tableView, dataSource) = self.makeTable()
        tableView.deselectAll(nil)
        var flags: [Bool] = []
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([30])
        applyPreservingSelection(snapshot, to: dataSource, in: tableView) { flags.append($0) }
        #expect(tableView.selectedRowIndexes.isEmpty)
        #expect(flags.isEmpty)
    }
}

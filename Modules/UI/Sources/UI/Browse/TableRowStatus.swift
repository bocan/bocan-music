import AppKit

// MARK: - TableRowStatus

/// Chooses the cell that speaks a table row's status, such as "Now playing"
/// or "file missing" (#694).
///
/// An AppKit table row cannot carry a label. Its accessibility element is a
/// private object with no description attribute, it does not read the
/// `NSTableRowView`, and `NSTableViewDelegate` has no method that asks for a
/// row label. VoiceOver reads the cells, so a fact about the whole row goes on
/// exactly one of them. Every column can be hidden, so that cell cannot simply
/// be Title.
@MainActor
enum TableRowStatus {
    /// The column whose cell speaks the status: `title` while it is showing,
    /// otherwise the first visible column that is not in `nonText`. Nil when
    /// no visible column can speak.
    static func carrierColumn(
        in tableView: NSTableView,
        title: NSUserInterfaceItemIdentifier,
        excluding nonText: Set<NSUserInterfaceItemIdentifier> = []
    ) -> NSUserInterfaceItemIdentifier? {
        let candidates = tableView.tableColumns.filter { !$0.isHidden && !nonText.contains($0.identifier) }
        return candidates.first { $0.identifier == title }?.identifier ?? candidates.first?.identifier
    }
}

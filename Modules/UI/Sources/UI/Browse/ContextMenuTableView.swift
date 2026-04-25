import AppKit

/// Routes right-click menus through a closure so the coordinator can read
/// `clickedRow` at the moment the menu is requested.
final class ContextMenuTableView: NSTableView {
    var menuProvider: (() -> NSMenu)?

    override func menu(for event: NSEvent) -> NSMenu? {
        self.menuProvider?() ?? super.menu(for: event)
    }
}

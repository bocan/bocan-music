import AppKit

/// Routes right-click menus through a closure so the coordinator can read
/// `clickedRow` at the moment the menu is requested.
final class ContextMenuTableView: NSTableView {
    var menuProvider: (() -> NSMenu)?
    /// Called when Delete/Forward Delete is pressed. Return `true` to consume.
    var deleteKeyHandler: (() -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? {
        self.menuProvider?() ?? super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.isDeleteKey(event), self.deleteKeyHandler?() == true {
            return
        }
        super.keyDown(with: event)
    }

    private static func isDeleteKey(_ event: NSEvent) -> Bool {
        event.keyCode == 51 || event.keyCode == 117
    }
}

import AppKit

/// Routes right-click menus through a closure so the coordinator can read
/// `clickedRow` at the moment the menu is requested.
final class ContextMenuTableView: NSTableView {
    var menuProvider: (() -> NSMenu)?
    /// Called when Delete/Forward Delete is pressed. Return `true` to consume.
    var deleteKeyHandler: (() -> Bool)?
    /// Called when Return or Enter is pressed. Triggers the play action.
    var returnKeyHandler: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        self.menuProvider?() ?? super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.isDeleteKey(event), self.deleteKeyHandler?() == true {
            return
        }
        if Self.isReturnKey(event), let handler = self.returnKeyHandler {
            handler()
            return
        }
        // ⌘A — explicitly delegate to NSTableView.selectAll so the standard
        // macOS "select all rows" affordance works even though we subclass keyDown.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "a" {
            self.selectAll(nil)
            return
        }
        super.keyDown(with: event)
    }

    private static func isDeleteKey(_ event: NSEvent) -> Bool {
        event.keyCode == 51 || event.keyCode == 117
    }

    private static func isReturnKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76 // Return or Enter (numeric keypad)
    }
}

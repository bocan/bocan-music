import AppKit

// MARK: - EditMenuRouting

/// Routes the Edit-menu select-all commands (#379).
///
/// A SwiftUI menu `keyboardShortcut` intercepts app-wide, ahead of the
/// responder chain, so a plain Cmd+A binding silently steals select-all from
/// whatever text field is being edited; the toolbar search box was the
/// reported victim, with tracks getting selected in a table the user was not
/// looking at. Menu actions consult this helper at action time; checking
/// focus at action time (rather than observing it) keeps the menu bar free
/// of high-frequency invalidation, per this module's menu rules.
@MainActor
public enum EditMenuRouting {
    /// The field editor to forward to, when `responder` is a text view. The
    /// macOS field editor backs every editing text field (the search box,
    /// tag editor fields, playlist renames), so this one check covers them.
    public static func textEditor(from responder: NSResponder?) -> NSTextView? {
        responder as? NSTextView
    }

    /// The key window's first responder. `NSApp` is an implicitly-unwrapped
    /// `NSApplication!` and is nil until an application object exists, so a
    /// bare `NSApp.keyWindow` crashes in headless contexts (SPM tests).
    private static var keyWindowResponder: NSResponder? {
        NSApp?.keyWindow?.firstResponder
    }

    /// True while a text view is first responder in the key window.
    public static var textEditorIsActive: Bool {
        self.textEditor(from: self.keyWindowResponder) != nil
    }

    /// Forwards Select All to the active field editor. Returns false when no
    /// text view has focus, in which case the caller keeps the command's
    /// browse meaning (select all tracks).
    public static func forwardSelectAllToTextEditor() -> Bool {
        guard let editor = self.textEditor(from: self.keyWindowResponder) else { return false }
        editor.selectAll(nil)
        return true
    }
}

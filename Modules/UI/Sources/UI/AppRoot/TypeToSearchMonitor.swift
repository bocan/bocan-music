import AppKit
import SwiftUI

// MARK: - TypeToSearchBackground

/// Zero-frame background helper wiring ``TypeToSearchMonitor`` to the library:
/// the seed character starts a fresh query and reuses the same focus-request
/// path as `⌘F`. Held as a plain `let` so the helper never re-renders on
/// view-model churn.
struct TypeToSearchBackground: View {
    let vm: LibraryViewModel

    var body: some View {
        TypeToSearchMonitor { char in
            self.vm.searchQuery = String(char)
            self.vm.requestSearchFocus()
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

// MARK: - TypeToSearchMonitor

/// Installs a local key-down monitor so the first printable keypress anywhere
/// in the main window begins a library search seeded with that character
/// (#369, Tauon-style type-to-search).
///
/// The monitor deliberately swallows the triggering event: focus moves to the
/// search field asynchronously, so letting the event continue would type the
/// character a second time. Guards keep every other keyboard interaction
/// intact:
/// - Only the window hosting this view reacts; Settings, the Mini Player, and
///   the Log Console keep their own key handling.
/// - Active text editing (the field editor: the search box itself, the tag
///   editor, a playlist rename) passes through untouched.
/// - Sheets and alerts pass through; they run their own key loops.
/// - Command / control / option chords pass through to menu shortcuts, and
///   whitespace, function, and navigation keys pass through to the grids' and
///   tables' existing handlers.
struct TypeToSearchMonitor: NSViewRepresentable {
    /// Called on the main actor with the character that should seed the search.
    let begin: (Character) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view, begin: self.begin)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    // MARK: - Eligibility

    /// Returns the seed character when a key event carrying `characters` (with
    /// `modifiers` held) should begin a search, or `nil` when the event must
    /// pass through. Pure, so the whole eligibility table is unit-testable
    /// without synthesizing key events.
    static func seedCharacter(
        for characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Character? {
        // Menu chords keep working. Shift alone stays eligible (capitals).
        guard modifiers.isDisjoint(with: [.command, .control, .option, .function]) else {
            return nil
        }
        guard let characters, characters.count == 1,
              let scalar = characters.unicodeScalars.first else {
            return nil
        }
        // Control characters (return, tab, escape) sit below 0x20, delete is
        // 0x7F, and function / navigation keys (arrows, F-keys, page keys)
        // land in the 0xF700 private-use range.
        guard scalar.value >= 0x20, scalar.value != 0x7F,
              !(0xF700 ... 0xF8FF).contains(scalar.value) else {
            return nil
        }
        let char = Character(scalar)
        guard !char.isWhitespace else { return nil }
        return char
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(for view: NSView, begin: @escaping (Character) -> Void) {
            guard self.monitor == nil else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
                // The monitor fires on the main thread, but the handler is not
                // @MainActor in the SDK; assume isolation for the AppKit reads
                // and return a Sendable verdict (NSEvent itself is not).
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let window = view?.window,
                          event.window === window,
                          window.attachedSheet == nil,
                          !(window.firstResponder is NSText),
                          let seed = TypeToSearchMonitor.seedCharacter(
                              for: event.characters,
                              modifiers: event.modifierFlags
                          ) else {
                        return false
                    }
                    begin(seed)
                    Self.moveCaretToEnd(in: window)
                    return true
                }
                // Swallow handled events: the character is already in the query.
                return handled ? nil : event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            self.monitor = nil
        }

        /// Focusing a text field selects its contents, which would make the
        /// next keystroke replace the seed character instead of extending it.
        /// Nudge the caret to the end once the field editor takes over,
        /// retrying across a few runloop turns because SwiftUI moves
        /// `@FocusState` asynchronously.
        private static func moveCaretToEnd(in window: NSWindow, attempt: Int = 0) {
            guard attempt < 8 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak window] in
                guard let window else { return }
                if let editor = window.firstResponder as? NSTextView {
                    editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
                } else {
                    self.moveCaretToEnd(in: window, attempt: attempt + 1)
                }
            }
        }
    }
}

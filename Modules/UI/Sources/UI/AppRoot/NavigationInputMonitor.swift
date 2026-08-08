import AppKit
import SwiftUI

// MARK: - NavigationInputBackground

/// Zero-frame helper wiring ``NavigationInputMonitor`` to the library (#378):
/// mouse back/forward side buttons walk the browse history like a browser,
/// and Esc backs out of a drill-down to its structural parent. Held as a
/// plain `let` so the helper never re-renders on view-model churn.
struct NavigationInputBackground: View {
    let vm: LibraryViewModel

    var body: some View {
        NavigationInputMonitor(
            onHistory: { direction in
                let vm = self.vm
                Task {
                    switch direction {
                    case .back:
                        await vm.goBack()

                    case .forward:
                        await vm.goForward()
                    }
                }
            },
            onDrillOut: { self.vm.drillOutToParent() }
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

// MARK: - NavigationInputMonitor

/// Installs local event monitors so browser-style navigation inputs reach the
/// browse history (#378):
///
/// - **Mouse buttons 3 and 4** (`otherMouseUp`) map to history back/forward,
///   the browser convention every multi-button mouse user expects.
/// - **Esc** (`keyDown`, key code 53) backs out of a drill-down to its
///   structural parent, deliberately *not* history-back: history can cross
///   sidebar sections, and Esc teleporting the user around would feel broken.
///
/// Guards keep every other interaction intact: only the window hosting this
/// view reacts; sheets, popovers, and other windows keep their own handling;
/// Esc passes through while a text view has focus (search exit, rename
/// cancel), in full screen (so fullscreen-exit still works), and whenever
/// there is no drill-down to leave.
struct NavigationInputMonitor: NSViewRepresentable {
    enum HistoryDirection {
        case back
        case forward
    }

    /// Called on the main actor with the history direction for a side button.
    let onHistory: (HistoryDirection) -> Void
    /// Called on the main actor for Esc; returns whether a drill-out actually
    /// navigated, so an unhandled Esc passes through untouched.
    let onDrillOut: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view, onHistory: self.onHistory, onDrillOut: self.onDrillOut)
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

    /// macOS delivers the thumb buttons as `otherMouse*` events with these
    /// button numbers; 0/1 are left/right and 2 is the middle wheel button.
    static func historyDirection(forButtonNumber number: Int) -> HistoryDirection? {
        switch number {
        case 3:
            .back

        case 4:
            .forward

        default:
            nil
        }
    }

    /// Esc, and only a bare Esc: chords stay available to menus and the
    /// system. Pure, so the eligibility is unit-testable without events.
    static func isBareEscape(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == 53 && modifiers.isDisjoint(with: [.command, .control, .option, .shift, .function])
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(
            for view: NSView,
            onHistory: @escaping (HistoryDirection) -> Void,
            onDrillOut: @escaping () -> Bool
        ) {
            guard self.monitor == nil else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.otherMouseUp, .keyDown]
            ) { [weak view] event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let window = view?.window,
                          event.window === window,
                          window.attachedSheet == nil else {
                        return false
                    }
                    if event.type == .otherMouseUp {
                        guard let direction = NavigationInputMonitor.historyDirection(
                            forButtonNumber: event.buttonNumber
                        ) else {
                            return false
                        }
                        onHistory(direction)
                        return true
                    }
                    // keyDown: Esc drill-out, last in its precedence ladder.
                    guard NavigationInputMonitor.isBareEscape(
                        keyCode: event.keyCode,
                        modifiers: event.modifierFlags
                    ),
                        !(window.firstResponder is NSText),
                        !window.styleMask.contains(.fullScreen) else {
                        return false
                    }
                    return onDrillOut()
                }
                return handled ? nil : event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            self.monitor = nil
        }
    }
}

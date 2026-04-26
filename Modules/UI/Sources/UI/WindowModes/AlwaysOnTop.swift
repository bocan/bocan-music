import AppKit
import SwiftUI

// MARK: - AlwaysOnTop

/// A view modifier that makes a window float above all others when `enabled`.
///
/// Usage:
/// ```swift
/// MiniPlayerView(vm: vm)
///     .modifier(AlwaysOnTop(enabled: vm.alwaysOnTop))
/// ```
public struct AlwaysOnTop: ViewModifier {
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public func body(content: Content) -> some View {
        content
            .background(WindowLevelSetter(level: self.enabled ? .floating : .normal))
    }
}

// MARK: - WindowLevelSetter (AppKit bridge)

/// A zero-size AppKit-backed view that reads its host window and mutates its level.
private struct WindowLevelSetter: NSViewRepresentable {
    let level: NSWindow.Level

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Defer one run-loop tick so the window is fully installed in the scene.
        DispatchQueue.main.async {
            nsView.window?.level = self.level
        }
    }
}

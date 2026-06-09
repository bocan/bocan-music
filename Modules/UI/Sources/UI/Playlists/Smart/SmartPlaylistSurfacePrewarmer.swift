import AppKit
import SwiftUI

// MARK: - SmartPlaylistSurfacePrewarmer

/// One-shot warm-up for smart-playlist UI surfaces that are first shown as
/// sheets during playback (`NewSmartPlaylistSheet`, `RuleBuilderView`,
/// `SmartPresetPickerView`).
@MainActor
enum SmartPlaylistSurfacePrewarmer {
    private static var didPrewarm = false

    static func prewarmOnce() {
        guard !self.didPrewarm else { return }
        self.didPrewarm = true

        // Use preferredFont so the warm-up exercises the same code path as real cells.
        _ = NSFont.preferredFont(forTextStyle: .body)
        let host = NSHostingView(rootView: SmartPlaylistWarmupProbeView())
        let panel = NSPanel(
            contentRect: NSRect(x: -20000, y: -20000, width: 24, height: 24),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.contentView = host
        panel.orderFront(nil)
        panel.orderOut(nil)
        panel.close()
    }
}

// MARK: - SmartPlaylistWarmupProbeView

/// Tiny off-screen probe view to warm text, segmented controls, and menus used
/// by smart-playlist sheets.
private struct SmartPlaylistWarmupProbeView: View {
    @State private var text = ""
    @State private var mode = 0

    var body: some View {
        VStack(spacing: 0) {
            TextField(L10n.string("Name"), text: self.$text)
                .textFieldStyle(.roundedBorder)
            Picker("", selection: self.$mode) {
                Text(localized: "all").tag(0)
                Text(localized: "any").tag(1)
            }
            .pickerStyle(.segmented)
            Menu(L10n.string("Preset")) {
                Button(L10n.string("Built-in")) {}
            }
        }
        .hidden()
        .frame(width: 1, height: 1)
    }
}

import AppKit

// MARK: - SinglePresentationGate

/// Lets one presentation run at a time and turns a second request away while
/// the first is still on screen.
///
/// A panel shown with `begin(completionHandler:)` does not block its window,
/// so nothing stops a second click on the button that opened it (#643).
@MainActor
final class SinglePresentationGate {
    private(set) var isPresenting = false

    /// Runs `present` unless a presentation is already running; in that case
    /// calls `whenBusy` and returns `busy` without running `present`.
    func run<Value>(
        busy: Value,
        whenBusy: () -> Void = {},
        _ present: () async -> Value
    ) async -> Value {
        guard !self.isPresenting else {
            whenBusy()
            return busy
        }
        self.isPresenting = true
        defer { self.isPresenting = false }
        return await present()
    }
}

// MARK: - LibraryViewModel + open panel

extension LibraryViewModel {
    /// One gate for every library picker (folders, files, listening history):
    /// they all add to the same library, so one at a time is enough.
    private static let openPanelGate = SinglePresentationGate()
    private weak static var presentedOpenPanel: NSOpenPanel?

    /// Async wrapper around `NSOpenPanel.begin(completionHandler:)`. Unlike
    /// `runModal()` this does **not** spin a nested modal run loop, so the
    /// audio engine's render callback keeps its scheduling priority while the
    /// panel is on screen (ADR-007 audit L2).
    ///
    /// Only one panel is open at a time. A request made while one is on
    /// screen brings that panel to the front and returns `.cancel`, so a
    /// second click on Add Folder… does not stack a second dialog (#643).
    static func runOpenPanelAsync(_ panel: NSOpenPanel) async -> NSApplication.ModalResponse {
        await self.openPanelGate.run(
            busy: .cancel,
            whenBusy: { self.presentedOpenPanel?.makeKeyAndOrderFront(nil) },
            {
                self.presentedOpenPanel = panel
                return await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
                    panel.begin { response in
                        continuation.resume(returning: response)
                    }
                }
            }
        )
    }
}

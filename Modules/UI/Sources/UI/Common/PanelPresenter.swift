import AppKit

// MARK: - SinglePresentationGate

/// Lets one presentation run at a time and turns a second request away while
/// the first is still on screen.
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

// MARK: - PanelPresenter

/// The one way this module shows an open or save panel.
///
/// `begin(completionHandler:)` is used rather than `runModal()` so no nested
/// modal run loop starves the audio render callback (ADR-007 audit L2). The
/// price is that the panel does not block its window, so nothing stops a
/// second click on the button that opened it: every picker stacked a second
/// dialog beside the first (#643). All panels therefore share one gate. A
/// request made while a panel is on screen brings that panel to the front
/// and returns `.cancel`.
///
/// Never call `begin` on a panel directly; `PanelPresenterTests` fails on one.
@MainActor
enum PanelPresenter {
    private static let gate = SinglePresentationGate()
    private weak static var presented: NSSavePanel?

    /// Shows `panel` (an `NSOpenPanel` is an `NSSavePanel`) and returns the
    /// user's answer, or `.cancel` at once when another panel is already open.
    static func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        await self.gate.run(
            busy: .cancel,
            whenBusy: { self.presented?.makeKeyAndOrderFront(nil) },
            {
                self.presented = panel
                return await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
                    panel.begin { response in
                        continuation.resume(returning: response)
                    }
                }
            }
        )
    }
}

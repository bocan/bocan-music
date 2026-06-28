import AppKit
import Observability
import SwiftUI

// MARK: - WindowSignpostBracket

/// Brackets a `Telemetry` signpost interval around the period the hosting window
/// is on screen.
///
/// SwiftUI's `Settings` scene window is uniquely awkward: on Cmd-W it is ordered
/// out, not torn down and not closed, and it keeps key status, so none of
/// `.onDisappear`, `willCloseNotification`, or `didResignKeyNotification` fire on
/// dismiss (verified empirically). The only thing that reflects the real state
/// is the window's `isVisible`, so once the interval is open we poll it on a
/// short timer that exists only while the window is up. The interval starts when
/// the window becomes key (open / reopen) and ends as soon as it is ordered out.
/// Mirrors the NSView/`viewDidMoveToWindow` pattern used by `MiniPlayerWindowSetup`
/// / `SidebarWidthAutosave`.
struct WindowSignpostBracket: NSViewRepresentable {
    let name: StaticString

    func makeNSView(context: Context) -> SpanView {
        SpanView(name: self.name)
    }

    func updateNSView(_ nsView: SpanView, context: Context) {}

    final class SpanView: NSView {
        private let name: StaticString
        // nonisolated(unsafe): touched from the nonisolated deinit. The signpost
        // end closure, Timer.invalidate, and removeObserver are all thread-safe
        // enough for teardown (the view deallocates on the main thread).
        private nonisolated(unsafe) var end: (@Sendable () -> Void)?
        private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
        private nonisolated(unsafe) var poll: Timer?

        init(name: StaticString) {
            self.name = name
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // viewDidMoveToWindow always runs on the main thread.
            guard let window, self.observers.isEmpty else { return }
            let center = NotificationCenter.default
            self.observers = [
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.start() }
                },
                center.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish() }
                },
            ]
            if window.isVisible { self.start() }
        }

        private func start() {
            guard self.end == nil, self.window?.isVisible == true else { return }
            self.end = Telemetry.timer(self.name)
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.window?.isVisible != true { self.finish() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.poll = timer
        }

        private func finish() {
            self.poll?.invalidate()
            self.poll = nil
            self.end?()
            self.end = nil
        }

        deinit {
            self.poll?.invalidate()
            self.end?()
            for observer in self.observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

import AppKit
import Testing
@testable import UI

// MARK: - WindowFadeTests

/// Lives at the UITests root (not ViewModelTests/) on purpose: these tests
/// create real `NSWindow`s, which need the SPM test environment, not the
/// host-less Xcode bundle.
@Suite("WindowFade")
@MainActor
struct WindowFadeTests {
    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        return win
    }

    // Synchronous tests: the seam is installed, used, and restored without a
    // suspension point, so concurrent tests cannot interleave (same pattern
    // as the Haptics spy tests).

    @Test("reduce motion: orderOut hides immediately and runs completion")
    func reducedMotionOrderOut() {
        let original = WindowFade.prefersReducedMotion
        defer { WindowFade.prefersReducedMotion = original }
        WindowFade.prefersReducedMotion = { true }

        let win = self.makeWindow()
        win.makeKeyAndOrderFront(nil)
        var completed = false
        WindowFade.orderOut(win) { completed = true }
        #expect(!win.isVisible)
        #expect(completed)
        #expect(win.alphaValue == 1)
        win.close()
    }

    @Test("reduce motion: makeKeyAndOrderFront shows immediately at full alpha")
    func reducedMotionOrderFront() {
        let original = WindowFade.prefersReducedMotion
        defer { WindowFade.prefersReducedMotion = original }
        WindowFade.prefersReducedMotion = { true }

        let win = self.makeWindow()
        WindowFade.makeKeyAndOrderFront(win)
        #expect(win.isVisible)
        #expect(win.alphaValue == 1)
        win.close()
    }

    @Test("reduce motion: fadeIn leaves the window fully opaque")
    func reducedMotionFadeIn() {
        let original = WindowFade.prefersReducedMotion
        defer { WindowFade.prefersReducedMotion = original }
        WindowFade.prefersReducedMotion = { true }

        let win = self.makeWindow()
        win.makeKeyAndOrderFront(nil)
        WindowFade.fadeIn(win)
        #expect(win.alphaValue == 1)
        win.close()
    }

    @Test("animated: orderOut keeps the window visible while fading, then hides and restores alpha")
    func animatedOrderOut() async throws {
        let original = WindowFade.prefersReducedMotion
        let originalDuration = WindowFade.duration
        defer {
            WindowFade.prefersReducedMotion = original
            WindowFade.duration = originalDuration
        }
        WindowFade.prefersReducedMotion = { false }
        WindowFade.duration = 0.02

        let win = self.makeWindow()
        win.makeKeyAndOrderFront(nil)
        var completed = false
        WindowFade.orderOut(win) { completed = true }
        // The fade is in flight: the window must still be on screen.
        #expect(win.isVisible)

        // Wait for the animation completion to hide the window.
        for _ in 0 ..< 100 {
            if completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(completed)
        #expect(!win.isVisible)
        #expect(win.alphaValue == 1)
        win.close()
    }
}

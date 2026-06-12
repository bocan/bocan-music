import AppKit

// MARK: - WindowFade

/// Short alpha cross-fades for the mini-player and main-window swap (#330).
///
/// Wraps `NSAnimationContext` alpha animation so the swap reads as one
/// surface morphing into another instead of two windows popping. Every
/// helper degrades to the immediate, animation-free behaviour when reduce
/// motion is active (system setting or the per-app Appearance toggle), and
/// always restores `alphaValue` to 1 so a later plain `orderFront` never
/// shows a stuck-transparent window.
@MainActor
enum WindowFade {
    /// Fade duration for one side of the swap. Internal var so tests can
    /// shorten it; the production value stays subtle and quick.
    static var duration: TimeInterval = 0.18

    /// Test seam. Production checks the system accessibility setting and
    /// the per-app reduce-motion toggle (Appearance Settings, issue #144).
    static var prefersReducedMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "appearance.reduceMotion")
    }

    /// Fades `window` to transparent, orders it out on completion, then
    /// restores full alpha. Immediate `orderOut` under reduce motion.
    static func orderOut(_ window: NSWindow, completion: (() -> Void)? = nil) {
        guard !self.prefersReducedMotion() else {
            window.orderOut(nil)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = self.duration
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1
            completion?()
        }
    }

    /// Orders `window` front as key, fading it in from transparent.
    /// Immediate `makeKeyAndOrderFront` under reduce motion.
    static func makeKeyAndOrderFront(_ window: NSWindow) {
        guard !self.prefersReducedMotion() else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        self.fadeToOpaque(window)
    }

    /// Fades an already-visible `window` in from transparent. No-op under
    /// reduce motion (the window simply stays at full alpha).
    static func fadeIn(_ window: NSWindow) {
        guard !self.prefersReducedMotion() else { return }
        window.alphaValue = 0
        self.fadeToOpaque(window)
    }

    // MARK: - Private

    private static func fadeToOpaque(_ window: NSWindow) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = self.duration
            window.animator().alphaValue = 1
        }
    }
}

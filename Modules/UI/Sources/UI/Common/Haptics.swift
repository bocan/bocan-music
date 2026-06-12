import AppKit

// MARK: - Haptics

/// Trackpad haptic feedback for discrete user actions (#330).
///
/// All calls route through `NSHapticFeedbackManager`, which is silently a
/// no-op on hardware without a haptic trackpad and honours the system
/// "Force Click and haptic feedback" trackpad setting. Funnelling every
/// call through this facade fixes one pattern per interaction kind and
/// gives tests an injection seam, and it fires exactly once per user
/// action regardless of how many windows (main strip, mini player,
/// menu bar extra) display the same control.
@MainActor
public enum Haptics {
    /// Test seam: tests swap this to record performed patterns.
    /// The production default routes to the system haptic performer.
    static var performPattern: (NSHapticFeedbackManager.FeedbackPattern) -> Void = { pattern in
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }

    /// A discrete state change the user just caused: love toggled,
    /// rating set, queue played through to its end.
    public static func stateChange() {
        self.performPattern(.levelChange)
    }

    /// A positional commit: a seek landing, the volume slider released.
    public static func positionCommit() {
        self.performPattern(.alignment)
    }
}

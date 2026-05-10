import AppKit
import Observation

// TODO: remove @preconcurrency when Sparkle adds Sendable annotations
@preconcurrency import Sparkle

/// Wraps `SPUStandardUpdaterController` and exposes update actions to the menu.
///
/// Created once in `BocanApp.init()` and held as a `private let`. The
/// updater starts automatically on launch, controlled by
/// `SUEnableAutomaticChecks` in Info.plist. Feed URL and automatic-update
/// preference are set via Info.plist keys; beta-channel overriding is
/// handled separately in issue #213.
///
/// `canCheckForUpdates` is a stored `@Observable` property updated via KVO so
/// the "Check for Updates…" button and menu item disable/enable reactively.
@Observable
@MainActor
final class UpdateController: NSObject {
    private let standardController: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    /// `true` when Sparkle is ready to perform a user-initiated check.
    private(set) var canCheckForUpdates = false

    override init() {
        self.standardController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        // KVO-observe canCheckForUpdates on the Sparkle updater so the UI
        // reflects readiness without polling. The closure is called immediately
        // with .initial and again whenever the property changes.
        self.observation = self.standardController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Triggers the standard Sparkle "Check for Updates…" sheet.
    func checkForUpdates() {
        self.standardController.checkForUpdates(nil)
    }
}

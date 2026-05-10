import AppKit

// TODO: remove @preconcurrency when Sparkle adds Sendable annotations
@preconcurrency import Sparkle

/// Wraps `SPUStandardUpdaterController` and exposes update actions to the menu.
///
/// Created once in `BocanApp.init()` and held as a `private let`. The
/// updater starts automatically on launch, controlled by
/// `SUEnableAutomaticChecks` in Info.plist. Feed URL and automatic-update
/// preference are set via Info.plist keys; beta-channel overriding is
/// handled separately in issue #213.
@MainActor
final class UpdateController: NSObject {
    private let standardController: SPUStandardUpdaterController

    override init() {
        self.standardController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Triggers the standard Sparkle "Check for Updates…" sheet.
    func checkForUpdates() {
        self.standardController.checkForUpdates(nil)
    }

    /// `true` when Sparkle is ready to perform a user-initiated check.
    var canCheckForUpdates: Bool {
        self.standardController.updater.canCheckForUpdates
    }
}

import Foundation
import Observability
import ServiceManagement

// MARK: - LaunchAtLoginController

/// Wires the `general.launchAtLogin` `@AppStorage` flag to `SMAppService.mainApp`.
///
/// Phase 4 audit C5: previously the toggle was defined in
/// `GeneralSettingsView` but never read.  This controller:
///
/// - Reconciles the on-disk login-item registration with the user default at
///   launch (so unregistering manually in System Settings is reflected).
/// - Exposes `setEnabled(_:)` for the Settings UI to call when the user
///   flips the toggle.
@MainActor
enum LaunchAtLoginController {
    private static let log = AppLogger.make(.app)
    private static let defaultsKey = "general.launchAtLogin"

    /// Reconciles the on-disk login-item state with the persisted preference.
    ///
    /// Should be called once at launch.  When the two disagree (user disabled
    /// the login item via System Settings, for example), the on-disk state
    /// wins and the preference is updated to match.
    static func reconcileAtLaunch() {
        let service = SMAppService.mainApp
        let isRegistered = service.status == .enabled
        let preferenceWanted = UserDefaults.standard.bool(forKey: self.defaultsKey)

        if preferenceWanted, !isRegistered {
            // User wants it on, but it isn't registered (perhaps freshly installed).
            self.setEnabled(true)
        } else if !preferenceWanted, isRegistered {
            // User flipped it off in System Settings while we were quit.
            // Trust the system state and flip the preference.
            UserDefaults.standard.set(true, forKey: self.defaultsKey)
        } else {
            self.log.debug("launchAtLogin.reconcile", [
                "preference": preferenceWanted,
                "registered": isRegistered,
            ])
        }
    }

    /// Registers or unregisters the app as a login item.
    ///
    /// Safe to call repeatedly.  Errors are logged; the toggle UI is kept
    /// in sync with the actual `SMAppService.status` after the attempt so
    /// the user sees an immediate revert if registration was denied.
    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                self.log.info("launchAtLogin.registered", [:])
            } else {
                try service.unregister()
                self.log.info("launchAtLogin.unregistered", [:])
            }
        } catch {
            self.log.error("launchAtLogin.failed", [
                "enabled": enabled,
                "error": String(reflecting: error),
            ])
            // Roll the user-default back to the actual on-disk state so the
            // Settings toggle reflects reality.
            let actualEnabled = service.status == .enabled
            UserDefaults.standard.set(actualEnabled, forKey: self.defaultsKey)
        }
    }
}

// MARK: - LaunchAtLoginObserver

/// Sink that listens for `UserDefaults.didChangeNotification` and forwards
/// `general.launchAtLogin` flips into `LaunchAtLoginController.setEnabled(_:)`.
///
/// `UserDefaults` does not expose individual keys as KVO-observable
/// properties, so we filter on the change notification instead and compare
/// against the last known value to avoid redundant register/unregister calls.
final class LaunchAtLoginObserver {
    private static let key = "general.launchAtLogin"
    private var lastKnownValue: Bool

    init() {
        self.lastKnownValue = UserDefaults.standard.bool(forKey: Self.key)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func defaultsChanged() {
        let current = UserDefaults.standard.bool(forKey: Self.key)
        guard current != self.lastKnownValue else { return }
        self.lastKnownValue = current
        Task { @MainActor in LaunchAtLoginController.setEnabled(current) }
    }
}

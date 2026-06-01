import AVKit
import Observability
import SwiftUI

// MARK: - Notification

/// Notification names posted by Bòcan for cross-component coordination.
public extension Notification.Name {
    /// Posted to programmatically open the system AirPlay route picker.
    ///
    /// `AirPlayButton`'s `Coordinator` observes this and forwards a simulated
    /// click to the `AVRoutePickerView`'s underlying `NSButton` subview.
    /// Post from the main thread only (e.g. a menu-item action or keyboard shortcut).
    static let bocanActivateRoutePicker = Notification.Name("io.cloudcauldron.bocan.activateRoutePicker")
}

// MARK: - AirPlayButton

/// Wraps `AVRoutePickerView` so a SwiftUI button presents the system AirPlay picker.
///
/// We deliberately don't restyle the view — picking AirPlay devices is a
/// system-owned interaction and Apple's HIG asks us to keep the standard
/// button shape. We only constrain its size to fit the transport strip.
///
/// Listens for `Notification.Name.bocanActivateRoutePicker` so the Playback
/// menu item (⌘⇧U) and keyboard shortcut can open the picker without a mouse.
public struct AirPlayButton: NSViewRepresentable {
    public init() {}

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.controlAccentColor, for: .normal)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        view.setAccessibilityLabel("AirPlay")
        view.toolTip = "Choose AirPlay output"
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    public func updateNSView(_: AVRoutePickerView, context _: Context) {
        // Stateless — system manages the picker.
    }

    // MARK: - Coordinator

    /// Holds a weak reference to the live `AVRoutePickerView` and opens the
    /// system picker in response to `Notification.Name.bocanActivateRoutePicker`.
    ///
    /// `@MainActor` because all state and methods touch AppKit views.
    /// The isolation also makes `Coordinator` implicitly `Sendable`, satisfying
    /// Swift 6's requirement for captures in `@Sendable` notification closures.
    @MainActor
    public final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        private let log = AppLogger.make(.cast)
        private weak var pickerView: AVRoutePickerView?
        /// `NSObjectProtocol` (the opaque observer token from NotificationCenter) is not
        /// `Sendable`. Marking it `nonisolated(unsafe)` lets `deinit` (which is always
        /// nonisolated) call `removeObserver` without a concurrency error.  The token is
        /// only written once on the main actor during `attach(to:)` and only read in
        /// `deinit`, so there is no real data race.
        private nonisolated(unsafe) var observer: NSObjectProtocol?

        /// Called once from `makeNSView` to wire up the view and the notification.
        func attach(to view: AVRoutePickerView) {
            self.pickerView = view
            self.observer = NotificationCenter.default.addObserver(
                forName: .bocanActivateRoutePicker,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Delivery is already on the main queue (queue: .main above).
                // `assumeIsolated` lets Swift 6 verify the main-actor isolation
                // statically without a redundant async hop.
                MainActor.assumeIsolated { self?.trigger() }
            }
        }

        /// `AVRoutePickerView` contains a system `NSButton` subview; forwarding
        /// `performClick` to it opens the route-picker popup programmatically.
        private func trigger() {
            guard let view = pickerView else {
                self.log.warning("cast.picker.activate.noView")
                return
            }
            if let button = view.subviews.first(where: { $0 is NSButton }) as? NSButton {
                self.log.info("cast.picker.activate", ["source": "notification"])
                button.performClick(nil)
            } else {
                self.log.warning("cast.picker.activate.noButton")
            }
        }

        // MARK: AVRoutePickerViewDelegate

        // These fire on the main thread but the protocol is not actor-annotated,
        // so they are `nonisolated`; they only touch the Sendable `log`.

        public nonisolated func routePickerViewWillBeginPresentingRoutes(_: AVRoutePickerView) {
            self.log.info("cast.picker.present.begin")
        }

        public nonisolated func routePickerViewDidEndPresentingRoutes(_: AVRoutePickerView) {
            // AVRoutePickerView gives us no selection callback (it routes AVPlayer
            // audio, which this app does not use), so the actual destination shows
            // up via the CoreAudio default-device observer, not here.
            self.log.info("cast.picker.present.end")
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

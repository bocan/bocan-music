import AudioEngine
import CoreAudio
import Foundation
import Observability
import Observation
import Playback
import SwiftUI

// MARK: - RouteViewModel

/// View model that publishes the current `Route` for the transport strip.
///
/// Created once in `BocanApp.init` and injected through the SwiftUI
/// environment. Spawns a single `Task` that consumes
/// `RouteManager.routes()` and republishes onto the main actor.
@MainActor
@Observable
public final class RouteViewModel {
    /// The current audio output route.
    public private(set) var current: Route = .local(name: "Built-in Output")

    private let manager: RouteManager?
    private let log = AppLogger.make(.cast)
    /// `@ObservationIgnored` keeps this as a plain stored var so that
    /// `nonisolated(unsafe)` is meaningful — `deinit` (nonisolated) needs
    /// to call `cancel()` on it, and the task handle doesn't need observation.
    @ObservationIgnored
    private nonisolated(unsafe) var consumer: Task<Void, Never>?

    /// Creates a `RouteViewModel` wired to the given `RouteManager`.
    public init(manager: RouteManager) {
        self.manager = manager
    }

    private init() {
        self.manager = nil
    }

    /// Inert view model with a specific initial route, for snapshot tests.
    /// Never starts a consumer task.
    init(initialRoute: Route) {
        self.manager = nil
        self.current = initialRoute
    }

    /// Inert view model used by previews and snapshot tests that don't care
    /// about route changes. Never starts a consumer task.
    public static let placeholder = RouteViewModel()

    /// Begin observing route changes. Idempotent.
    public func start() {
        guard self.consumer == nil, let mgr = manager else {
            self.log.debug("cast.routeVM.start.skipped", ["hasManager": self.manager != nil])
            return
        }
        self.log.debug("cast.routeVM.start")
        self.consumer = Task { [weak self] in
            await mgr.start()
            for await route in mgr.routes() {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    if route != self.current {
                        self.log.info("cast.routeVM.route", [
                            "name": route.displayName,
                            "kind": route.subtitle ?? "local",
                        ])
                    }
                    self.current = route
                }
            }
        }
    }

    /// The CoreAudio output devices currently available, for the device menu.
    /// Enumerated on demand (cheap) so the list is fresh each time the menu opens.
    public func availableDevices() -> [DeviceInfo] {
        DeviceRouter.outputDevices()
    }

    /// The id of the current system default output device, for the menu checkmark.
    public func currentDefaultDeviceID() -> AudioDeviceID? {
        DeviceRouter.defaultOutputDevice()?.id
    }

    /// Route audio to `device` by making it the system default output. The
    /// engine follows the change (via its HAL observer) and re-routes playback;
    /// `RouteManager` observes it and updates the chip. This is system-wide
    /// output selection, the path that actually moves AVAudioEngine audio.
    public func selectDevice(_ device: DeviceInfo) {
        self.log.info("cast.routeVM.select", ["device": device.name, "id": Int(device.id)])
        if !DeviceRouter.setDefaultOutputDevice(device.id) {
            self.log.error("cast.routeVM.select.failed", ["device": device.name, "id": Int(device.id)])
        }
    }

    /// Stops observing route changes and cancels the consumer task.
    public func stop() {
        self.log.debug("cast.routeVM.stop")
        self.consumer?.cancel()
        self.consumer = nil
    }

    deinit {
        self.consumer?.cancel()
    }
}

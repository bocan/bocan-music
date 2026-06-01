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

    /// The device this app's audio is pinned to, or `nil` while following the
    /// system default. Drives the checkmark in the output-device menu.
    public private(set) var selectedDeviceID: AudioDeviceID?

    private let manager: RouteManager?
    /// Routes this app's audio to a chosen device (`nil` = system default).
    /// Injected by the App layer, which owns the concrete `AudioEngine`.
    private let setDevice: (@Sendable (AudioDeviceID?) async -> Void)?
    private let log = AppLogger.make(.cast)
    /// `@ObservationIgnored` keeps this as a plain stored var so that
    /// `nonisolated(unsafe)` is meaningful — `deinit` (nonisolated) needs
    /// to call `cancel()` on it, and the task handle doesn't need observation.
    @ObservationIgnored
    private nonisolated(unsafe) var consumer: Task<Void, Never>?

    /// Creates a `RouteViewModel` wired to the given `RouteManager`.
    ///
    /// - Parameter setDevice: routes this app's audio to a device id (or `nil`
    ///   for the system default). When omitted the device menu is observe-only.
    public init(
        manager: RouteManager,
        setDevice: (@Sendable (AudioDeviceID?) async -> Void)? = nil
    ) {
        self.manager = manager
        self.setDevice = setDevice
    }

    private init() {
        self.manager = nil
        self.setDevice = nil
    }

    /// Inert view model with a specific initial route, for snapshot tests.
    /// Never starts a consumer task.
    init(initialRoute: Route) {
        self.manager = nil
        self.setDevice = nil
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
                    // While pinned to an app-only device, the system-default route
                    // the manager reports is not where our audio is going, so don't
                    // let it overwrite the chip.
                    guard self.selectedDeviceID == nil else {
                        self.log.debug("cast.routeVM.route.ignoredWhilePinned", ["system": route.displayName])
                        return
                    }
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

    /// Route this app's audio to `device`, or pass `nil` to follow the system
    /// default again. Updates the chip immediately and hands off to the engine.
    public func selectDevice(_ device: DeviceInfo?) {
        self.selectedDeviceID = device?.id
        if let device {
            self.log.info("cast.routeVM.select", ["device": device.name, "id": Int(device.id)])
            self.current = .external(name: device.name, kind: "Output")
        } else {
            self.log.info("cast.routeVM.select", ["device": "system-default"])
            // Fall back to whatever the manager last reported as the system route.
            Task { [weak self] in
                guard let self, let mgr = self.manager else { return }
                let route = await mgr.current
                await MainActor.run { self.current = route }
            }
        }
        let setDevice = self.setDevice
        let id = device?.id
        Task { await setDevice?(id) }
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

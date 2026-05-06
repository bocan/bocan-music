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
    private let log = AppLogger.make(.playback)
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

    /// Inert view model used by previews and snapshot tests that don't care
    /// about route changes. Never starts a consumer task.
    public static let placeholder = RouteViewModel()

    /// Begin observing route changes. Idempotent.
    public func start() {
        guard self.consumer == nil, let mgr = manager else { return }
        self.consumer = Task { [weak self] in
            await mgr.start()
            for await route in mgr.routes() {
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.current = route
                }
            }
        }
    }

    /// Stops observing route changes and cancels the consumer task.
    public func stop() {
        self.consumer?.cancel()
        self.consumer = nil
    }

    deinit {
        self.consumer?.cancel()
    }
}

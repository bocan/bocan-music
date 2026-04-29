import Foundation
import Observability
import Playback
import SwiftUI

// MARK: - RouteViewModel

/// View model that publishes the current `Route` for the transport strip.
///
/// Created once in `BocanApp.init` and injected through the SwiftUI
/// environment. Spawns a single `Task` that consumes
/// `RouteManager.routes()` and republishes onto the main actor.
@MainActor
public final class RouteViewModel: ObservableObject {
    @Published public private(set) var current: Route = .local(name: "Built-in Output")

    private let manager: RouteManager?
    private let log = AppLogger.make(.playback)
    private var consumer: Task<Void, Never>?

    public init(manager: RouteManager) {
        self.manager = manager
    }

    /// Inert view model used by previews and snapshot tests that don't care
    /// about route changes. Never starts a consumer task.
    private init() {
        self.manager = nil
    }

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

    public func stop() {
        self.consumer?.cancel()
        self.consumer = nil
    }

    deinit {
        self.consumer?.cancel()
    }
}

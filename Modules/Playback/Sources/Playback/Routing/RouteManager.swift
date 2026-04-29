import Foundation
import Observability

// MARK: - RouteManager

/// Observes the system's default output device and re-broadcasts it as a
/// `Route` value.
///
/// This is purely an *observer* — picking AirPlay devices is the user's
/// job (via the system picker). We just keep the UI honest about where
/// audio is going.
public actor RouteManager {
    // MARK: - State

    public private(set) var current: Route = .local(name: "Built-in Output")

    private let provider: any OutputDeviceProvider
    private let log = AppLogger.make(.playback)

    private var consumeTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<Route>.Continuation] = [:]

    // MARK: - Init

    public init(provider: any OutputDeviceProvider) {
        self.provider = provider
    }

    // MARK: - Lifecycle

    /// Subscribe to the provider's update stream and re-publish as `Route`.
    /// Idempotent — subsequent calls are no-ops while a task is running.
    public func start() async {
        guard self.consumeTask == nil else { return }
        self.log.debug("routing.start")

        // Seed `current` from a one-shot read so subscribers see a sensible
        // value before the first update arrives.
        let seed = await self.provider.current()
        self.current = Self.route(for: seed)
        self.fanout(self.current)

        let stream = self.provider.updates()
        self.consumeTask = Task { [weak self] in
            for await info in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                await self.handle(info)
            }
        }
    }

    /// Tear down the consumer task. Pending subscribers stay open; they just
    /// stop receiving new values.
    public func stop() async {
        self.consumeTask?.cancel()
        self.consumeTask = nil
        self.log.debug("routing.stop")
    }

    // MARK: - Subscription

    /// Stream of `Route` values. Emits the current route immediately, then
    /// again on every change.
    public nonisolated func routes() -> AsyncStream<Route> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.attach(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                Task { await self.detach(id: id) }
            }
        }
    }

    private func attach(id: UUID, continuation: AsyncStream<Route>.Continuation) {
        self.subscribers[id] = continuation
        continuation.yield(self.current)
    }

    private func detach(id: UUID) {
        self.subscribers.removeValue(forKey: id)
    }

    // MARK: - Mapping

    private func handle(_ info: OutputDeviceInfo) {
        let route = Self.route(for: info)
        guard route != self.current else { return }
        self.current = route
        self.log.info("routing.changed", [
            "name": route.displayName,
            "kind": route.subtitle ?? "local",
        ])
        self.fanout(route)
    }

    private func fanout(_ route: Route) {
        for cont in self.subscribers.values {
            cont.yield(route)
        }
    }

    /// Pure mapping from a HAL snapshot to a `Route`. Exposed `internal` for
    /// unit tests that don't want to spin up the actor.
    static func route(for info: OutputDeviceInfo) -> Route {
        switch info.transportType {
        case .builtIn:
            .local(name: info.name)

        case .airPlay:
            .airPlay(name: info.name)

        case .bluetooth, .bluetoothLE, .hdmi, .displayPort,
             .usb, .thunderbolt, .aggregate, .virtual, .unknown:
            .external(name: info.name, kind: info.transportType.kindLabel)
        }
    }
}

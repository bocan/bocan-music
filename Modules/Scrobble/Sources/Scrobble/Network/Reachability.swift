import Foundation
import Network

// MARK: - Reachability

/// Provides a stream of "is the network usable?" booleans driven by `NWPathMonitor`.
///
/// Used by `ScrobbleQueueWorker` to pause submissions while offline and resume
/// the moment a path becomes satisfied. The worker subscribes once at startup
/// and never tears the monitor down.
public protocol Reachability: Sendable {
    /// Current snapshot of reachability.
    func currentlyReachable() async -> Bool
    /// A stream that yields a value whenever reachability changes.
    func updates() async -> AsyncStream<Bool>
}

// MARK: - SystemReachability

/// `NWPathMonitor`-backed implementation. Safe to use in production.
public actor SystemReachability: Reachability {
    private let monitor: NWPathMonitor
    private var current = false
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var started = false

    public init() {
        self.monitor = NWPathMonitor()
    }

    deinit {
        self.monitor.cancel()
    }

    private func ensureStarted() {
        guard !self.started else { return }
        self.started = true
        let queue = DispatchQueue(label: "io.cloudcauldron.bocan.scrobble.reachability")
        self.monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = path.status == .satisfied
            Task { await self.handle(reachable) }
        }
        self.monitor.start(queue: queue)
        self.current = self.monitor.currentPath.status == .satisfied
    }

    private func handle(_ reachable: Bool) {
        guard reachable != self.current else { return }
        self.current = reachable
        for cont in self.continuations.values {
            cont.yield(reachable)
        }
    }

    public func currentlyReachable() -> Bool {
        self.ensureStarted()
        return self.current
    }

    public func updates() -> AsyncStream<Bool> {
        self.ensureStarted()
        let initial = self.current
        return AsyncStream { continuation in
            let id = UUID()
            self.add(id: id, continuation: continuation)
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.remove(id: id) }
            }
        }
    }

    private func add(id: UUID, continuation: AsyncStream<Bool>.Continuation) {
        self.continuations[id] = continuation
    }

    private func remove(id: UUID) {
        self.continuations.removeValue(forKey: id)
    }
}

// MARK: - StaticReachability

/// Test/dev fixture: reachability is whatever the test sets it to be.
public actor StaticReachability: Reachability {
    private var reachable: Bool
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init(reachable: Bool = true) {
        self.reachable = reachable
    }

    public func currentlyReachable() -> Bool {
        self.reachable
    }

    public func updates() -> AsyncStream<Bool> {
        let initial = self.reachable
        return AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.remove(id: id) }
            }
        }
    }

    public func set(_ reachable: Bool) {
        guard reachable != self.reachable else { return }
        self.reachable = reachable
        for cont in self.continuations.values {
            cont.yield(reachable)
        }
    }

    private func remove(id: UUID) {
        self.continuations.removeValue(forKey: id)
    }
}

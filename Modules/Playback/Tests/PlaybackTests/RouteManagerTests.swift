import Foundation
import Testing
@testable import Playback

// MARK: - MockOutputDeviceProvider

private final class MockOutputDeviceProvider: OutputDeviceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var initial: OutputDeviceInfo
    private var continuations: [AsyncStream<OutputDeviceInfo>.Continuation] = []

    init(initial: OutputDeviceInfo) {
        self.initial = initial
    }

    func current() async -> OutputDeviceInfo {
        self.read { $0 }
    }

    func updates() -> AsyncStream<OutputDeviceInfo> {
        AsyncStream { continuation in
            let seed: OutputDeviceInfo = self.write { state in
                self.continuations.append(continuation)
                return state
            }
            continuation.yield(seed)
        }
    }

    /// Push a new device to all subscribers.
    func push(_ info: OutputDeviceInfo) {
        let conts: [AsyncStream<OutputDeviceInfo>.Continuation] = self.write { _ in
            self.initial = info
            return self.continuations
        }
        for c in conts {
            c.yield(info)
        }
    }

    /// Synchronous, lock-only helpers — never called from async context paths
    /// that would trip the runtime's lock-from-async checker.
    private func read<T>(_ block: (OutputDeviceInfo) -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return block(self.initial)
    }

    private func write<T>(_ block: (OutputDeviceInfo) -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return block(self.initial)
    }
}

// MARK: - Helpers

private func builtIn(_ name: String = "Built-in Speakers") -> OutputDeviceInfo {
    OutputDeviceInfo(deviceID: 1, name: name, transportType: .builtIn)
}

private func airPlay(_ name: String = "Living Room") -> OutputDeviceInfo {
    OutputDeviceInfo(deviceID: 2, name: name, transportType: .airPlay)
}

private func bluetooth(_ name: String = "AirPods") -> OutputDeviceInfo {
    OutputDeviceInfo(deviceID: 3, name: name, transportType: .bluetooth)
}

/// Wrap an `AsyncStream<Route>.AsyncIterator` so we can pass it to escaping
/// closures (the bare iterator is `inout`-only). Single-consumer use.
private final class IteratorBox: @unchecked Sendable {
    var iterator: AsyncStream<Route>.AsyncIterator
    init(_ iterator: AsyncStream<Route>.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async -> Route? {
        await self.iterator.next()
    }
}

/// Read the next route from a stream within `timeoutMs`. Returns `nil` on timeout.
private func awaitRoute(
    _ box: IteratorBox,
    timeoutMs: UInt64 = 1000
) async -> Route? {
    await withTaskGroup(of: Route?.self) { group in
        group.addTask { await box.next() }
        group.addTask {
            try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? nil
    }
}

// MARK: - RouteManagerTests

@Suite("RouteManager")
struct RouteManagerTests {
    @Test("static mapping: built-in → .local")
    func mapBuiltIn() {
        let r = RouteManager.route(for: builtIn("Speakers"))
        #expect(r == .local(name: "Speakers"))
    }

    @Test("static mapping: airPlay → .airPlay")
    func mapAirPlay() {
        let r = RouteManager.route(for: airPlay("HomePod"))
        #expect(r == .airPlay(name: "HomePod"))
    }

    @Test("static mapping: bluetooth → .external(kind: Bluetooth)")
    func mapBluetooth() {
        let r = RouteManager.route(for: bluetooth("Bose"))
        #expect(r == .external(name: "Bose", kind: "Bluetooth"))
    }

    @Test("static mapping: aggregate → .external(kind: Aggregate)")
    func mapAggregate() {
        let info = OutputDeviceInfo(deviceID: 4, name: "Loopback", transportType: .aggregate)
        #expect(RouteManager.route(for: info) == .external(name: "Loopback", kind: "Aggregate"))
    }

    @Test("start() seeds current from the provider")
    func startSeeds() async {
        let mock = MockOutputDeviceProvider(initial: airPlay("HomePod"))
        let mgr = RouteManager(provider: mock)
        await mgr.start()
        let current = await mgr.current
        #expect(current == .airPlay(name: "HomePod"))
        await mgr.stop()
    }

    @Test("start() is idempotent")
    func startIdempotent() async {
        let mock = MockOutputDeviceProvider(initial: builtIn())
        let mgr = RouteManager(provider: mock)
        await mgr.start()
        await mgr.start()
        let current = await mgr.current
        #expect(current == .local(name: "Built-in Speakers"))
        await mgr.stop()
    }

    @Test("subscribers receive the current route immediately")
    func subscribeSeed() async {
        let mock = MockOutputDeviceProvider(initial: airPlay("HomePod"))
        let mgr = RouteManager(provider: mock)
        await mgr.start()
        let stream = mgr.routes()
        let iter = IteratorBox(stream.makeAsyncIterator())
        let first = await awaitRoute(iter)
        #expect(first == .airPlay(name: "HomePod"))
        await mgr.stop()
    }

    @Test("provider push surfaces a new route on the stream")
    func pushPropagates() async {
        let mock = MockOutputDeviceProvider(initial: builtIn("Built-in"))
        let mgr = RouteManager(provider: mock)
        await mgr.start()
        let stream = mgr.routes()
        let iter = IteratorBox(stream.makeAsyncIterator())
        // Drain the seed value.
        _ = await awaitRoute(iter)

        mock.push(airPlay("Kitchen"))
        let next = await awaitRoute(iter, timeoutMs: 2000)
        #expect(next == .airPlay(name: "Kitchen"))
        await mgr.stop()
    }

    @Test("identical pushes are deduplicated")
    func pushDedup() async {
        let mock = MockOutputDeviceProvider(initial: builtIn("Built-in"))
        let mgr = RouteManager(provider: mock)
        await mgr.start()
        let stream = mgr.routes()
        let iter = IteratorBox(stream.makeAsyncIterator())
        _ = await awaitRoute(iter) // seed

        // Push the same value the manager already holds — manager deduplicates,
        // so the next emission must come from the *real* change below.
        mock.push(builtIn("Built-in"))
        mock.push(airPlay("Den"))
        let next = await awaitRoute(iter, timeoutMs: 2000)
        #expect(next == .airPlay(name: "Den"))
        await mgr.stop()
    }
}

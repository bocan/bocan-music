import Foundation
import Synchronization

/// Process-wide, bounded ring buffer for captured log lines.
///
/// Every log line emitted through `AppLogger` is teed into the shared
/// instance so that `LogConsoleView` can backfill since-launch history and
/// tail new lines live.
///
/// All mutable state is protected by a `Mutex`; `record` is synchronous,
/// lock-guarded, and never blocks on I/O.
public final class LogStore: Sendable {
    // MARK: - Singleton

    /// App-wide singleton that `AppLogger` tees into.
    public static let shared = LogStore(capacity: 5000)

    // MARK: - State

    private struct State {
        var buffer: [LogEntry?]
        var head = 0 // index of the oldest valid entry
        var count = 0 // number of valid entries (0...capacity)
        var nextID: UInt64 = 0
        var isCaptureEnabled = true
        var subscribers: [UInt64: AsyncStream<LogEntry>.Continuation] = [:]
        var nextSubscriberID: UInt64 = 0

        init(capacity: Int) {
            self.buffer = Array(repeating: nil, count: capacity)
        }
    }

    private let _state: Mutex<State>

    // MARK: - Public interface

    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "LogStore capacity must be positive")
        self.capacity = capacity
        self._state = Mutex(State(capacity: capacity))
    }

    /// Number of active live subscribers. Exposed for tests via `@testable import`.
    var subscriberCount: Int {
        self._state.withLock { $0.subscribers.count }
    }

    /// The number of entries currently held in the ring buffer.
    public var count: Int {
        self._state.withLock { $0.count }
    }

    /// When `false`, `record` is a cheap no-op; `os.Logger` output is unaffected.
    /// On by default.
    public var isCaptureEnabled: Bool {
        get { self._state.withLock { $0.isCaptureEnabled } }
        set { self._state.withLock { $0.isCaptureEnabled = newValue } }
    }

    /// Append one log line to the ring buffer and broadcast to all live subscribers.
    ///
    /// Called from any thread / actor. Synchronous and lock-guarded.
    /// When the buffer is full, the oldest entry is evicted.
    /// Continuations are copied under the lock and yielded outside it to prevent
    /// re-entrancy and potential deadlock.
    /// Must never call `AppLogger` (no recursion into the logging facade).
    ///
    /// - Parameter at: Timestamp for the entry. Defaults to the current wall-clock
    ///   time. Pass a fixed value in tests to get deterministic snapshots.
    public func record(
        level: LogLevel,
        category: LogCategory,
        message: String,
        at timestamp: Date = Date()
    ) {
        let cap = self.capacity
        var broadcastEntry: LogEntry?
        var continuations: [AsyncStream<LogEntry>.Continuation] = []
        self._state.withLock { s in
            guard s.isCaptureEnabled else { return }
            let entry = LogEntry(
                id: s.nextID,
                timestamp: timestamp,
                level: level,
                category: category,
                message: message
            )
            s.nextID += 1
            if s.count < cap {
                // Buffer has room: write at the next free slot.
                let writeIndex = (s.head + s.count) % cap
                s.buffer[writeIndex] = entry
                s.count += 1
            } else {
                // Buffer is full: overwrite the oldest slot and advance head.
                s.buffer[s.head] = entry
                s.head = (s.head + 1) % cap
            }
            broadcastEntry = entry
            // Snapshot the continuations under the lock; yield outside.
            continuations = Array(s.subscribers.values)
        }
        // Yield outside the lock: yielding inside risks re-entrancy and deadlock.
        if let entry = broadcastEntry {
            for continuation in continuations {
                continuation.yield(entry)
            }
        }
    }

    /// Returns a snapshot of the current buffer contents, oldest entry first.
    public func snapshot() -> [LogEntry] {
        let cap = self.capacity
        return self._state.withLock { s in
            guard s.count > 0 else { return [] }
            var result = [LogEntry]()
            result.reserveCapacity(s.count)
            for i in 0 ..< s.count {
                let index = (s.head + i) % cap
                // buffer[index] is guaranteed non-nil for indices within count.
                result.append(s.buffer[index]!)
            }
            return result
        }
    }

    /// Empties the ring buffer.
    ///
    /// Already-displayed view copies are unaffected; this only clears the
    /// in-memory store so future `snapshot()` calls start fresh.
    public func clear() {
        self._state.withLock { s in
            s.head = 0
            s.count = 0
        }
    }

    /// Atomically returns the current buffer snapshot and registers a live subscriber.
    ///
    /// The `backfill` contains everything currently in the ring (oldest first).
    /// The `live` stream yields every entry recorded *after* the snapshot is taken,
    /// so no line is missed or duplicated across the seam.
    ///
    /// The subscriber is automatically removed when the consuming task is cancelled
    /// or the stream otherwise terminates. Uses `bufferingNewest` so a slow consumer
    /// cannot cause unbounded memory growth; the ring buffer is the real history.
    public func backfillAndSubscribe() -> (backfill: [LogEntry], live: AsyncStream<LogEntry>) {
        let cap = self.capacity
        // `makeStream` separates construction from the builder closure, which lets us
        // register the continuation inside a single `withLock` call alongside the
        // snapshot. Because `record` also holds the lock while writing, any line
        // recorded concurrently is either already in the snapshot or will be yielded
        // to the now-registered continuation — no line is missed or duplicated.
        let (stream, continuation) = AsyncStream.makeStream(
            of: LogEntry.self,
            bufferingPolicy: .bufferingNewest(cap)
        )
        let (backfill, token): ([LogEntry], UInt64) = self._state.withLock { s in
            // Snapshot the current ring buffer.
            var result = [LogEntry]()
            if s.count > 0 {
                result.reserveCapacity(s.count)
                for i in 0 ..< s.count {
                    result.append(s.buffer[(s.head + i) % cap]!)
                }
            }
            // Register the subscriber atomically with the snapshot.
            let token = s.nextSubscriberID
            s.nextSubscriberID += 1
            s.subscribers[token] = continuation
            return (result, token)
        }
        // `onTermination` calls `_removeSubscriber` which re-takes the lock, so it
        // must be set outside `withLock` to avoid recursive locking.
        continuation.onTermination = { [weak self] _ in
            self?._removeSubscriber(token: token)
        }
        return (backfill: backfill, live: stream)
    }

    // MARK: - Private helpers

    private func _removeSubscriber(token: UInt64) {
        self._state.withLock { s in
            s.subscribers.removeValue(forKey: token)
        }
    }
}

import Testing
@testable import Observability

@Suite("LogStore")
struct LogStoreTests {
    // MARK: - Append order

    @Test("snapshot returns entries in insertion order, oldest first")
    func appendOrder() {
        let store = LogStore(capacity: 10)
        store.record(level: .debug, category: .audio, message: "first")
        store.record(level: .info, category: .audio, message: "second")
        store.record(level: .warning, category: .audio, message: "third")

        let entries = store.snapshot()
        #expect(entries.count == 3)
        #expect(entries[0].message == "first")
        #expect(entries[1].message == "second")
        #expect(entries[2].message == "third")
    }

    @Test("capacity property matches value passed to init")
    func capacityProperty() {
        let store = LogStore(capacity: 42)
        #expect(store.capacity == 42)
    }

    // MARK: - Capacity eviction

    @Test("oldest entries are dropped when capacity is exceeded")
    func capacityEviction() {
        let store = LogStore(capacity: 3)
        store.record(level: .debug, category: .audio, message: "a")
        store.record(level: .debug, category: .audio, message: "b")
        store.record(level: .debug, category: .audio, message: "c")
        store.record(level: .debug, category: .audio, message: "d") // evicts "a"

        let entries = store.snapshot()
        #expect(entries.count == 3)
        #expect(entries[0].message == "b")
        #expect(entries[1].message == "c")
        #expect(entries[2].message == "d")
    }

    @Test("snapshot count never exceeds capacity")
    func snapshotCountNeverExceedsCapacity() {
        let capacity = 5
        let store = LogStore(capacity: capacity)
        for i in 0 ..< (capacity * 4) {
            store.record(level: .debug, category: .audio, message: "msg-\(i)")
        }
        #expect(store.snapshot().count == capacity)
    }

    @Test("buffer wraps correctly over multiple full rotations")
    func multipleRotations() {
        let capacity = 4
        let store = LogStore(capacity: capacity)
        // Write 3x the capacity so the ring wraps twice.
        for i in 0 ..< (capacity * 3) {
            store.record(level: .debug, category: .audio, message: "msg-\(i)")
        }
        let entries = store.snapshot()
        #expect(entries.count == capacity)
        // The last `capacity` messages should be msg-8 through msg-11 (0-based).
        let expectedStart = capacity * 3 - capacity
        for (offset, entry) in entries.enumerated() {
            #expect(entry.message == "msg-\(expectedStart + offset)")
        }
    }

    // MARK: - clear

    @Test("clear empties the buffer so snapshot returns empty")
    func clearEmptiesBuffer() {
        let store = LogStore(capacity: 10)
        store.record(level: .debug, category: .audio, message: "msg")
        store.clear()
        #expect(store.snapshot().isEmpty)
    }

    @Test("recording after clear works normally")
    func recordAfterClear() {
        let store = LogStore(capacity: 10)
        store.record(level: .debug, category: .audio, message: "before")
        store.clear()
        store.record(level: .info, category: .library, message: "after")

        let entries = store.snapshot()
        #expect(entries.count == 1)
        #expect(entries[0].message == "after")
        #expect(entries[0].level == .info)
        #expect(entries[0].category == .library)
    }

    @Test("clear on an empty store is a no-op")
    func clearEmptyStore() {
        let store = LogStore(capacity: 10)
        store.clear()
        #expect(store.snapshot().isEmpty)
    }

    // MARK: - isCaptureEnabled

    @Test("record is a no-op when capture is disabled")
    func captureDisabledNoOp() {
        let store = LogStore(capacity: 10)
        store.isCaptureEnabled = false
        store.record(level: .debug, category: .audio, message: "should not appear")
        #expect(store.snapshot().isEmpty)
    }

    @Test("re-enabling capture resumes recording")
    func captureReenabling() {
        let store = LogStore(capacity: 10)
        store.isCaptureEnabled = false
        store.record(level: .debug, category: .audio, message: "missed")
        store.isCaptureEnabled = true
        store.record(level: .debug, category: .audio, message: "captured")

        let entries = store.snapshot()
        #expect(entries.count == 1)
        #expect(entries[0].message == "captured")
    }

    @Test("capture is enabled by default")
    func captureEnabledByDefault() {
        let store = LogStore(capacity: 10)
        #expect(store.isCaptureEnabled == true)
    }

    // MARK: - Monotonic IDs

    @Test("ids are strictly increasing in snapshot order")
    func idsStrictlyIncreasing() {
        let store = LogStore(capacity: 20)
        for i in 0 ..< 10 {
            store.record(level: .debug, category: .audio, message: "msg-\(i)")
        }
        let entries = store.snapshot()
        for i in 1 ..< entries.count {
            #expect(entries[i].id > entries[i - 1].id)
        }
    }

    @Test("ids are unique after capacity wrap-around")
    func idsUniqueAfterWrap() {
        let capacity = 3
        let store = LogStore(capacity: capacity)
        for i in 0 ..< (capacity * 4) {
            store.record(level: .debug, category: .audio, message: "msg-\(i)")
        }
        let entries = store.snapshot()
        let ids = entries.map(\.id)
        #expect(Set(ids).count == ids.count, "IDs must be unique after wrap")
    }

    @Test("ids continue incrementing across a clear")
    func idsMonotonicAcrossClear() {
        let store = LogStore(capacity: 10)
        store.record(level: .debug, category: .audio, message: "before")
        let idBefore = store.snapshot()[0].id
        store.clear()
        store.record(level: .debug, category: .audio, message: "after")
        let idAfter = store.snapshot()[0].id
        #expect(idAfter > idBefore)
    }

    // MARK: - Entry field preservation

    @Test("stored entry preserves all fields")
    func entryFieldsPreserved() throws {
        let store = LogStore(capacity: 5)
        store.record(level: .fault, category: .subsonic, message: "test.fault [k=v]")

        let entry = try #require(store.snapshot().first)
        #expect(entry.level == .fault)
        #expect(entry.category == .subsonic)
        #expect(entry.message == "test.fault [k=v]")
    }

    // MARK: - Thread-safety smoke test

    @Test("concurrent record from a TaskGroup does not corrupt state")
    func concurrentRecordSafety() async {
        let capacity = 100
        let store = LogStore(capacity: capacity)
        let taskCount = 10
        let recordsPerTask = 50 // 500 total > capacity, so eviction also exercised

        await withTaskGroup(of: Void.self) { group in
            for t in 0 ..< taskCount {
                group.addTask {
                    for i in 0 ..< recordsPerTask {
                        store.record(level: .debug, category: .audio, message: "t\(t)-i\(i)")
                    }
                }
            }
        }

        let entries = store.snapshot()

        // Buffer must be exactly at capacity (500 writes > 100 slots).
        #expect(entries.count == capacity)

        // IDs must be unique (no corrupt double-write).
        let ids = entries.map(\.id)
        #expect(Set(ids).count == ids.count, "All IDs in snapshot must be unique")

        // IDs must be monotonically increasing in snapshot order (oldest first).
        for i in 1 ..< entries.count {
            #expect(entries[i].id > entries[i - 1].id)
        }
    }
}

// MARK: - Live broadcast tests

@Suite("LogStore live broadcast")
struct LogStoreBroadcastTests {
    // MARK: - Subscriber sees only post-backfill lines

    @Test("subscriber receives only lines recorded after backfillAndSubscribe")
    func subscriberSeesOnlyPostBackfillLines() async {
        let store = LogStore(capacity: 20)
        store.record(level: .debug, category: .audio, message: "pre-1")
        store.record(level: .debug, category: .audio, message: "pre-2")

        let (backfill, stream) = store.backfillAndSubscribe()

        store.record(level: .info, category: .library, message: "post-1")
        store.record(level: .info, category: .library, message: "post-2")

        var liveEntries: [LogEntry] = []
        for await entry in stream {
            liveEntries.append(entry)
            if liveEntries.count == 2 { break }
        }

        #expect(backfill.map(\.message) == ["pre-1", "pre-2"])
        #expect(liveEntries.map(\.message) == ["post-1", "post-2"])
    }

    @Test("backfill is empty when the store is empty at subscribe time")
    func backfillEmptyWhenStoreEmpty() async {
        let store = LogStore(capacity: 10)
        let (backfill, stream) = store.backfillAndSubscribe()

        store.record(level: .debug, category: .audio, message: "first")

        var liveEntries: [LogEntry] = []
        for await entry in stream {
            liveEntries.append(entry)
            if liveEntries.count == 1 { break }
        }

        #expect(backfill.isEmpty)
        #expect(liveEntries.map(\.message) == ["first"])
    }

    // MARK: - Two subscribers

    @Test("two subscribers each receive every new line")
    func twoSubscribersReceiveAllLines() async {
        let store = LogStore(capacity: 20)

        let (_, stream1) = store.backfillAndSubscribe()
        let (_, stream2) = store.backfillAndSubscribe()

        let messages = ["msg-a", "msg-b", "msg-c"]
        for msg in messages {
            store.record(level: .debug, category: .audio, message: msg)
        }

        var r1: [String] = []
        var r2: [String] = []

        await withTaskGroup(of: (Int, [String]).self) { group in
            group.addTask {
                var acc: [String] = []
                for await entry in stream1 {
                    acc.append(entry.message)
                    if acc.count == messages.count { break }
                }
                return (1, acc)
            }
            group.addTask {
                var acc: [String] = []
                for await entry in stream2 {
                    acc.append(entry.message)
                    if acc.count == messages.count { break }
                }
                return (2, acc)
            }
            for await (id, result) in group {
                if id == 1 { r1 = result } else { r2 = result }
            }
        }

        #expect(r1 == messages)
        #expect(r2 == messages)
    }

    // MARK: - No gap at the seam

    @Test("backfill and live stream have no gap and no duplicates across the seam")
    func noGapNoDuplicateAtSeam() async {
        let store = LogStore(capacity: 50)

        for i in 0 ..< 5 {
            store.record(level: .debug, category: .audio, message: "pre-\(i)")
        }

        let (backfill, stream) = store.backfillAndSubscribe()

        for i in 0 ..< 5 {
            store.record(level: .info, category: .library, message: "post-\(i)")
        }

        var liveEntries: [LogEntry] = []
        for await entry in stream {
            liveEntries.append(entry)
            if liveEntries.count == 5 { break }
        }

        let all = backfill + liveEntries

        // No duplicate IDs across the seam.
        let ids = all.map(\.id)
        #expect(Set(ids).count == ids.count, "IDs must be unique across backfill + live seam")

        // IDs are strictly increasing (total order preserved).
        for i in 1 ..< all.count {
            #expect(all[i].id > all[i - 1].id)
        }

        // Correct partitioning: pre-subscribe in backfill, post-subscribe in live.
        #expect(backfill.map(\.message) == (0 ..< 5).map { "pre-\($0)" })
        #expect(liveEntries.map(\.message) == (0 ..< 5).map { "post-\($0)" })
    }

    // MARK: - Subscriber cleanup on cancellation

    @Test("cancelling the consuming task removes the subscriber from the map")
    func cancellingTaskRemovesSubscriber() async {
        let store = LogStore(capacity: 10)

        let (_, stream) = store.backfillAndSubscribe()
        #expect(store.subscriberCount == 1)

        let task = Task {
            for await _ in stream {}
        }
        task.cancel()
        // Wait for the task to fully terminate so onTermination fires.
        _ = await task.result

        #expect(store.subscriberCount == 0)
    }

    @Test("multiple subscribers cleaned up independently on cancellation")
    func multipleSubscriberCleanup() async {
        let store = LogStore(capacity: 10)

        let (_, stream1) = store.backfillAndSubscribe()
        let (_, stream2) = store.backfillAndSubscribe()
        #expect(store.subscriberCount == 2)

        let task1 = Task { for await _ in stream1 {} }
        task1.cancel()
        _ = await task1.result
        #expect(store.subscriberCount == 1)

        let task2 = Task { for await _ in stream2 {} }
        task2.cancel()
        _ = await task2.result
        #expect(store.subscriberCount == 0)
    }

    @Test("recording after subscriber cancellation does not grow the subscriber map")
    func recordAfterCancellationDoesNotLeakSubscriber() async {
        let store = LogStore(capacity: 10)

        let (_, stream) = store.backfillAndSubscribe()
        let task = Task { for await _ in stream {} }
        task.cancel()
        _ = await task.result

        store.record(level: .debug, category: .audio, message: "post-cancel")
        #expect(store.subscriberCount == 0)
    }
}

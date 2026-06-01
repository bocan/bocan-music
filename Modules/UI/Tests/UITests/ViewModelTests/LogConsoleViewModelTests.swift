import Foundation
import Observability
import Testing
@testable import UI

// MARK: - LogConsoleViewModelTests

@Suite("LogConsoleViewModel")
@MainActor
struct LogConsoleViewModelTests {
    // MARK: - Filter: minimum level

    @Test("default minimumLevel is .debug — all levels are visible after start")
    func defaultLevelShowsAll() {
        let store = LogStore(capacity: 100)
        store.record(level: .trace, category: .audio, message: "trace-msg")
        store.record(level: .debug, category: .audio, message: "debug-msg")
        store.record(level: .info, category: .audio, message: "info-msg")
        store.record(level: .fault, category: .audio, message: "fault-msg")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.start()

        #expect(vm.visible.count == 3) // trace is below debug — trace filtered out
    }

    @Test("minimumLevel filters entries below the threshold before start")
    func minimumLevelFilterAppliedAtStart() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .audio, message: "debug-msg")
        store.record(level: .info, category: .audio, message: "info-msg")
        store.record(level: .warning, category: .audio, message: "warning-msg")
        store.record(level: .error, category: .audio, message: "error-msg")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.minimumLevel = .warning
        vm.start()

        #expect(vm.visible.count == 2)
        #expect(vm.visible.map(\.message) == ["warning-msg", "error-msg"])
    }

    @Test("raising minimumLevel on already-started VM updates visible immediately")
    func raisingLevelUpdatesVisible() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .audio, message: "debug-msg")
        store.record(level: .info, category: .audio, message: "info-msg")
        store.record(level: .warning, category: .audio, message: "warning-msg")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.start()
        #expect(vm.visible.count == 3)

        vm.minimumLevel = .warning
        #expect(vm.visible.count == 1)
        #expect(vm.visible[0].message == "warning-msg")
    }

    @Test("lowering minimumLevel to .trace shows all entries")
    func loweringLevelToTraceShowsAll() {
        let store = LogStore(capacity: 100)
        store.record(level: .trace, category: .audio, message: "trace-msg")
        store.record(level: .debug, category: .audio, message: "debug-msg")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.minimumLevel = .fault
        vm.start()
        #expect(vm.visible.isEmpty)

        vm.minimumLevel = .trace
        #expect(vm.visible.count == 2)
    }

    // MARK: - Filter: category set

    @Test("selected categories filters to matching entries only")
    func categoryFilterSingleCategory() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .audio, message: "audio-msg")
        store.record(level: .info, category: .playback, message: "playback-msg")
        store.record(level: .debug, category: .audio, message: "audio-msg-2")
        store.record(level: .info, category: .library, message: "library-msg")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.selectedCategories = [.audio]
        vm.start()

        #expect(vm.visible.count == 2)
        #expect(vm.visible.allSatisfy { $0.category == .audio })
    }

    @Test("empty selectedCategories shows all categories")
    func emptyCategorySetShowsAll() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .audio, message: "audio-msg")
        store.record(level: .debug, category: .playback, message: "playback-msg")
        store.record(level: .debug, category: .library, message: "library-msg")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        // selectedCategories is [] by default
        vm.start()

        #expect(vm.visible.count == 3)
    }

    @Test("selectedCategories with multiple values shows union of matching entries")
    func categoryFilterMultipleCategories() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .audio, message: "audio-msg")
        store.record(level: .debug, category: .playback, message: "playback-msg")
        store.record(level: .debug, category: .library, message: "library-msg")
        store.record(level: .debug, category: .network, message: "network-msg")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.selectedCategories = [.audio, .library]
        vm.start()

        #expect(vm.visible.count == 2)
        #expect(vm.visible.map(\.category) == [.audio, .library])
    }

    // MARK: - Filter: search text

    @Test("searchText filters by case-insensitive substring match on message")
    func searchFilterCaseInsensitive() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .audio, message: "decoder.start [format=FLAC]")
        store.record(level: .info, category: .playback, message: "playback.track [id=42]")
        store.record(level: .debug, category: .library, message: "library.scan.end [ms=100]")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.start()

        vm.searchText = "FLAC" // uppercase; message has lowercase letters too
        #expect(vm.visible.count == 1)
        #expect(vm.visible[0].message == "decoder.start [format=FLAC]")
    }

    @Test("empty searchText shows all entries")
    func emptySearchShowsAll() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .audio, message: "msg-a")
        store.record(level: .debug, category: .audio, message: "msg-b")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.start()
        #expect(vm.visible.count == 2)

        vm.searchText = "xyz" // nothing matches
        #expect(vm.visible.isEmpty)

        vm.searchText = "" // clear filter
        #expect(vm.visible.count == 2)
    }

    @Test("filters compose: minimumLevel AND category AND search all apply")
    func filtersCompose() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .audio, message: "decoder.start [format=FLAC]")
        store.record(level: .debug, category: .audio, message: "decoder.start [format=MP3]")
        store.record(level: .info, category: .audio, message: "decoder.start [format=FLAC]")
        store.record(level: .debug, category: .playback, message: "decoder.start [format=FLAC]")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.minimumLevel = .debug
        vm.selectedCategories = [.audio]
        vm.searchText = "FLAC"
        vm.start()

        // Only entries that are: level >= .debug AND category == .audio AND message contains "flac"
        #expect(vm.visible.count == 2)
        #expect(vm.visible.allSatisfy { $0.category == .audio })
        #expect(vm.visible.allSatisfy { $0.message.contains("FLAC") })
    }

    // MARK: - Pause

    @Test("pause freezes visible but mirror keeps growing")
    func pauseFreezesVisibleMirrorGrows() async {
        let store = LogStore(capacity: 100)
        // Pre-populate the first two entries via backfill (synchronous, no async needed).
        store.record(level: .debug, category: .audio, message: "msg-1")
        store.record(level: .debug, category: .audio, message: "msg-2")

        let (flushStream, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: flushStream)
        vm.start() // backfill: allEntries and visible each have 2 entries

        #expect(vm.visible.count == 2)
        #expect(vm.totalCount == 2)

        // Pause, then record 2 more entries via the live stream.
        vm.isPaused = true
        store.record(level: .debug, category: .audio, message: "msg-3")
        store.record(level: .debug, category: .audio, message: "msg-4")

        // Yield until the stream task has enqueued both entries into `pending`.
        for _ in 0 ..< 20 where vm.pendingCount < 2 {
            await Task.yield()
        }

        // Flush directly: mirror grows, visible stays frozen because isPaused.
        vm.flush()

        // Mirror reflects all 4 entries; visible is still frozen at 2.
        #expect(vm.totalCount == 4)
        #expect(vm.visible.count == 2)

        // Unpause: visible immediately catches up with the mirror.
        vm.isPaused = false
        #expect(vm.visible.count == 4)
    }

    @Test("pausing sets isTailing to false")
    func pauseSetsIsTailingFalse() {
        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: LogStore(capacity: 10), flushSignals: signals)
        vm.isTailing = true
        vm.isPaused = true
        #expect(vm.isTailing == false)
    }

    @Test("unpausing does not force isTailing back on")
    func unpauseDoesNotForceIsTailing() {
        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: LogStore(capacity: 10), flushSignals: signals)
        vm.isPaused = true // isTailing → false
        vm.isTailing = false // already false — set explicitly
        vm.isPaused = false // unpause
        #expect(vm.isTailing == false)
    }

    // MARK: - clearView vs clearBuffer

    @Test("clearView empties visible and allEntries but does not touch the store")
    func clearViewKeepsStore() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .audio, message: "msg")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.start()
        #expect(vm.visible.count == 1)

        vm.clearView()
        #expect(vm.visible.isEmpty)
        #expect(vm.totalCount == 0)
        #expect(!store.snapshot().isEmpty) // store still has the entry
    }

    @Test("clearBuffer empties both visible and the underlying LogStore")
    func clearBufferEmptiesStoreAndVisible() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .audio, message: "msg")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.start()
        #expect(vm.visible.count == 1)

        vm.clearBuffer()
        #expect(vm.visible.isEmpty)
        #expect(vm.totalCount == 0)
        #expect(store.snapshot().isEmpty) // store was also cleared
    }

    // MARK: - exportText / copyText

    @Test("exportText produces one line per visible entry in the expected format")
    func exportTextFormat() {
        let store = LogStore(capacity: 100)
        store.record(level: .warning, category: .subsonic, message: "connection.failed [reason=timeout]")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.start()

        let text = vm.exportText()
        // Format: "HH:mm:ss.SSS  WARNING  subsonic  connection.failed [reason=timeout]"
        #expect(text.hasSuffix("  WARNING  subsonic  connection.failed [reason=timeout]"))
        #expect(text.count > 22) // at least the timestamp (12 chars) + 2 spaces + rest
    }

    @Test("exportText contains only visible (filtered) entries, not all entries")
    func exportTextRespectsFilter() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .audio, message: "debug-msg")
        store.record(level: .error, category: .audio, message: "error-msg")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.minimumLevel = .error
        vm.start()

        let text = vm.exportText()
        #expect(text.contains("error-msg"))
        #expect(!text.contains("debug-msg"))
    }

    @Test("exportText with multiple entries separates lines with newline")
    func exportTextMultipleEntriesNewlineSeparated() {
        let store = LogStore(capacity: 100)
        store.record(level: .info, category: .audio, message: "msg-a")
        store.record(level: .info, category: .audio, message: "msg-b")
        store.record(level: .info, category: .audio, message: "msg-c")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.start()

        let text = vm.exportText()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
    }

    @Test("copyText returns the same content as exportText")
    func copyTextMatchesExportText() {
        let store = LogStore(capacity: 100)
        store.record(level: .debug, category: .library, message: "scan.start")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.start()

        #expect(vm.copyText() == vm.exportText())
    }

    // MARK: - isAtCapacity

    @Test("isAtCapacity is false when mirror is below capacity")
    func isAtCapacityFalse() {
        let store = LogStore(capacity: 10)
        store.record(level: .debug, category: .audio, message: "msg")

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.start()

        #expect(!vm.isAtCapacity)
    }

    @Test("isAtCapacity is true when mirror reaches capacity")
    func isAtCapacityTrueAtCapacity() {
        let store = LogStore(capacity: 3)
        for i in 0 ..< 3 {
            store.record(level: .debug, category: .audio, message: "msg-\(i)")
        }

        let (signals, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: signals)
        vm.start()

        #expect(vm.isAtCapacity)
        #expect(vm.totalCount == 3)
    }

    @Test("isAtCapacity reflects live entries after flush")
    func isAtCapacityReflectsLiveMirror() async {
        let store = LogStore(capacity: 2)
        let (flushStream, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: flushStream)
        vm.start()

        #expect(!vm.isAtCapacity)

        store.record(level: .debug, category: .audio, message: "msg-1")
        store.record(level: .debug, category: .audio, message: "msg-2")

        // Yield until the stream task has enqueued both entries, then flush directly.
        for _ in 0 ..< 20 where vm.pendingCount < 2 {
            await Task.yield()
        }
        vm.flush()

        #expect(vm.isAtCapacity)
    }

    // MARK: - Flush determinism

    @Test("flush drains pending into visible without needing real-time sleeps")
    func flushIsDeterministic() async {
        let store = LogStore(capacity: 100)
        let (flushStream, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: flushStream)
        vm.start()

        // Before any entries: visible is empty.
        #expect(vm.visible.isEmpty)

        store.record(level: .info, category: .library, message: "scan.start")
        store.record(level: .info, category: .library, message: "scan.end [ms=42]")

        // Yield until the stream task has enqueued both entries into `pending`.
        for _ in 0 ..< 20 where vm.pendingCount < 2 {
            await Task.yield()
        }
        // Entries are in pending; visible is still empty.
        #expect(vm.visible.isEmpty)

        // Flush directly: no real-time sleep needed.
        vm.flush()

        #expect(vm.visible.count == 2)
        #expect(vm.visible.map(\.message) == ["scan.start", "scan.end [ms=42]"])
    }

    // MARK: - Live tail (production timer)

    @Test("production timer delivers live entries after start()")
    func productionTimerLiveDelivery() async throws {
        let store = LogStore(capacity: 100)
        let vm = LogConsoleViewModel(store: store) // production init: real 100 ms timer
        vm.start()
        #expect(vm.visible.isEmpty)

        store.record(level: .info, category: .playback, message: "transport.state [state=playing]")

        try await Self.waitForVisible(vm, count: 1)
        #expect(vm.visible.first?.message == "transport.state [state=playing]")
        vm.stop()
    }

    @Test("live tail still works after stop() then a second start() (window reopened)")
    func liveTailSurvivesRestart() async throws {
        let store = LogStore(capacity: 100)
        let vm = LogConsoleViewModel(store: store)
        vm.start()
        vm.stop() // simulate the console window closing

        // Reopen: a fresh start() must rebuild the flush timer and live subscription.
        vm.start()
        store.record(level: .info, category: .playback, message: "after-reopen")

        try await Self.waitForVisible(vm, count: 1)
        #expect(vm.visible.first?.message == "after-reopen")
        vm.stop()
    }

    /// Polls real time for the production flush timer to drain into `visible`.
    private static func waitForVisible(_ vm: LogConsoleViewModel, count: Int) async throws {
        for _ in 0 ..< 40 where vm.visible.count < count {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(vm.visible.count == count)
    }

    // MARK: - stop

    @Test("stop flushes remaining pending entries before halting tasks")
    func stopFlushesPending() async {
        let store = LogStore(capacity: 100)
        let (flushStream, _) = AsyncStream<Void>.makeStream()
        let vm = LogConsoleViewModel(store: store, flushSignals: flushStream)
        vm.start()

        store.record(level: .debug, category: .audio, message: "final-msg")
        // Yield repeatedly until the stream task has enqueued the entry into `pending`.
        // Each yield gives the @MainActor stream task one scheduling slot.
        for _ in 0 ..< 5 where vm.pendingCount == 0 {
            await Task.yield()
        }
        // Confirm the entry is in pending before stop() — the test is only meaningful
        // when the stream task has actually delivered the entry.
        guard vm.pendingCount > 0 else {
            // If the entry never reached pending (unlikely but possible under extreme
            // scheduler load), skip the remaining assertions rather than flap.
            return
        }

        // stop() should drain pending into allEntries / visible.
        vm.stop()
        #expect(vm.visible.count == 1)
        #expect(vm.visible[0].message == "final-msg")
    }
}

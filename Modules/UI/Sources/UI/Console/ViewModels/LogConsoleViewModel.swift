import Foundation
import Observability

// MARK: - LogConsoleViewModel

/// View model for the in-app log console window.
///
/// Call `start()` from the view's `task {}` modifier and `stop()` from `onDisappear`.
/// The store is injected so tests can drive it in isolation; production code uses
/// the default `LogStore.shared`.
///
/// Entries arrive in two phases:
/// 1. **Backfill** – the current ring-buffer contents, ingested synchronously in `start()`.
/// 2. **Live stream** – new entries yielded by `LogStore.backfillAndSubscribe()`, consumed
///    by a background task and flushed into the observable state in batches at ~10 Hz so
///    a burst of log lines does not saturate the main actor on every single write.
///
/// The flush rate is controlled by an injected `AsyncStream<Void>` tick source. Production
/// uses a 100 ms timer; tests inject a manually-fired stream for deterministic control.
@MainActor
@Observable
public final class LogConsoleViewModel {
    // MARK: - Public inputs (toolbar bindings)

    /// Minimum level shown. Default `.debug`, matching the `log stream` terminal command.
    public var minimumLevel: LogLevel = .debug {
        didSet { self.refilter() }
    }

    /// Selected categories shown. An empty set means all categories. Default all.
    public var selectedCategories: Set<LogCategory> = [] {
        didSet { self.refilter() }
    }

    /// Case-insensitive substring match on `LogEntry.message`. Empty = no filter.
    public var searchText = "" {
        didSet { self.refilter() }
    }

    /// When `true` new live entries do not flow into `visible`. The internal mirror
    /// keeps growing so unpausing shows everything accumulated during the pause.
    /// Setting `true` also forces `isTailing = false`.
    public var isPaused = false {
        didSet {
            if self.isPaused, !oldValue {
                self.isTailing = false
            } else if !self.isPaused, oldValue {
                self.refilter()
            }
        }
    }

    /// When `true` the view auto-scrolls to the newest row as entries arrive.
    public var isTailing = true

    // MARK: - Public outputs (read-only)

    /// Filtered, visible entries; oldest first. Updated by each flush (when not paused)
    /// and whenever a filter input changes.
    public private(set) var visible: [LogEntry] = []

    /// Total unfiltered entry count in the local mirror (not the store snapshot).
    public var totalCount: Int {
        self.allEntries.count
    }

    /// `true` when the local mirror has reached `store.capacity` and oldest lines are
    /// being silently dropped on each new entry. Used to surface a capacity banner.
    public var isAtCapacity: Bool {
        self.allEntries.count >= self.store.capacity
    }

    // MARK: - Private state

    /// Full unfiltered mirror of received entries, capped at `store.capacity`.
    private var allEntries: [LogEntry] = []

    /// Live-stream entries buffered between flush ticks.
    private var pending: [LogEntry] = []

    // MARK: - Dependencies

    private let store: LogStore

    /// Test-injected flush tick stream. When non-nil, `start()` consumes this
    /// instead of spinning up the production 100 ms timer, so tests can drive
    /// flushes deterministically. `nil` in production.
    private let injectedFlushSignals: AsyncStream<Void>?

    // nonisolated(unsafe): assigned only from @MainActor methods and read once
    // from the nonisolated `deinit`, which has exclusive access — never concurrently.
    // Task handles are themselves Sendable. See #279.
    private nonisolated(unsafe) var streamTask: Task<Void, Never>?
    private nonisolated(unsafe) var flushTask: Task<Void, Never>?
    private nonisolated(unsafe) var timerTask: Task<Void, Never>?

    // MARK: - Init

    /// Production initialiser. The flush timer is created lazily in `start()` so
    /// the view model can be stopped and started again (e.g. the console window
    /// closed and reopened) without losing the live tail.
    public init(store: LogStore = .shared) {
        self.store = store
        self.injectedFlushSignals = nil
    }

    /// Internal initialiser for deterministic tests.
    ///
    /// Pass a manually-controlled `AsyncStream<Void>` and fire its continuation to
    /// trigger flushes at precise moments without real-time sleeps.
    init(store: LogStore, flushSignals: AsyncStream<Void>) {
        self.store = store
        self.injectedFlushSignals = flushSignals
    }

    deinit {
        self.timerTask?.cancel()
        self.streamTask?.cancel()
        self.flushTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Begin backfilling and subscribing to the live entry stream.
    ///
    /// Synchronously seeds `visible` from the current store contents, then starts
    /// two background tasks: one that enqueues live entries into `pending`, and one
    /// that drains `pending` into `allEntries` and refilters `visible` on each tick.
    public func start() {
        // Idempotent: tear down any prior subscription/timer first so a second
        // start() (window reopened, or the view re-appearing) does not leak tasks
        // or attach a second consumer to an already-iterated flush stream.
        self.cancelTasks()

        let (backfill, live) = self.store.backfillAndSubscribe()

        // Ingest the backfill synchronously so `visible` is populated before the
        // view appears, with no async round-trip.
        if !backfill.isEmpty {
            self.applyBatch(backfill)
        }

        // Consume the live stream: just enqueue into `pending` (cheap, main-actor,
        // no filter work on every single line).
        self.streamTask = Task { [weak self] in
            for await entry in live {
                guard !Task.isCancelled else { break }
                self?.pending.append(entry)
            }
        }

        // Build a fresh flush-tick stream for this run. Production spins up a
        // 100 ms timer; tests consume the injected stream. Creating it here (not
        // in init) is what lets start()/stop() cycle without losing the tail.
        let signals = self.makeFlushSignals()
        self.flushTask = Task { [weak self] in
            for await _ in signals {
                guard !Task.isCancelled else { break }
                self?.flush()
            }
        }
    }

    /// Returns the flush-tick stream for a `start()` run. In production this also
    /// starts the 100 ms timer task feeding it; in tests it returns the injected
    /// stream untouched (the test drives it, or calls `flush()` directly).
    private func makeFlushSignals() -> AsyncStream<Void> {
        if let injected = self.injectedFlushSignals {
            return injected
        }
        let (stream, cont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.timerTask = Task.detached(priority: .utility) { [cont] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                cont.yield()
            }
            cont.finish()
        }
        return stream
    }

    /// Cancels the live-stream, flush, and timer tasks and clears their handles.
    private func cancelTasks() {
        self.timerTask?.cancel()
        self.streamTask?.cancel()
        self.flushTask?.cancel()
        self.timerTask = nil
        self.streamTask = nil
        self.flushTask = nil
    }

    /// Stop streaming and flush any remaining pending entries.
    ///
    /// Call from the view's `onDisappear` so a closed window does not keep draining.
    public func stop() {
        self.cancelTasks()
        // Drain any entries that arrived before the tasks were cancelled.
        if !self.pending.isEmpty {
            self.applyBatch(self.pending)
            self.pending.removeAll()
        }
    }

    // MARK: - Actions

    /// Clears the local view state without touching the underlying `LogStore`.
    ///
    /// A fresh `start()` call would re-backfill from the store.
    public func clearView() {
        self.allEntries.removeAll()
        self.pending.removeAll()
        self.visible.removeAll()
    }

    /// Clears both the local view state and the underlying `LogStore` ring buffer.
    public func clearBuffer() {
        self.store.clear()
        self.clearView()
    }

    /// Formatted text for the currently visible (filtered) entries, suitable for
    /// writing to a `.log` file via a save panel.
    ///
    /// Format per line: `HH:mm:ss.SSS  LEVEL  category  message`
    public func exportText() -> String {
        self.visible.map { Self.formatLine($0) }.joined(separator: "\n")
    }

    /// Same as `exportText()`, for clipboard use.
    public func copyText() -> String {
        self.exportText()
    }

    // MARK: - Internal (accessible from tests)

    /// Number of entries buffered but not yet flushed. Accessible from tests to confirm
    /// stream task delivery before calling `stop()` or `flush()` directly.
    var pendingCount: Int {
        self.pending.count
    }

    /// Drain `pending` into `allEntries` and recompute `visible` (unless paused).
    ///
    /// Called automatically by the flush task on each tick. Also callable directly
    /// from tests after `await Task.yield()` to drive state without real-time sleeps.
    func flush() {
        guard !self.pending.isEmpty else { return }
        self.applyBatch(self.pending)
        self.pending.removeAll(keepingCapacity: true)
    }

    // MARK: - Private helpers

    /// Append `entries` to `allEntries` (capping at capacity) and update `visible`
    /// if the view is not currently paused.
    private func applyBatch(_ entries: [LogEntry]) {
        let cap = self.store.capacity
        self.allEntries.append(contentsOf: entries)
        if self.allEntries.count > cap {
            self.allEntries.removeFirst(self.allEntries.count - cap)
        }
        if !self.isPaused {
            self.refilter()
        }
    }

    /// Recompute `visible` from `allEntries` using the current filter state.
    ///
    /// Always runs to completion: calling it while paused will update `visible` to
    /// reflect changed filter inputs (intentional — the user explicitly changed a
    /// filter control, so the current snapshot should react immediately).
    private func refilter() {
        var result = self.allEntries
        if self.minimumLevel > .trace {
            result = result.filter { $0.level >= self.minimumLevel }
        }
        if !self.selectedCategories.isEmpty {
            result = result.filter { self.selectedCategories.contains($0.category) }
        }
        if !self.searchText.isEmpty {
            let needle = self.searchText.lowercased()
            result = result.filter { $0.message.lowercased().contains(needle) }
        }
        self.visible = result
    }

    /// Render one `LogEntry` as a single flat line.
    private static func formatLine(_ entry: LogEntry) -> String {
        let ts = self.timestampFormatter.string(from: entry.timestamp)
        return "\(ts)  \(entry.level.label)  \(entry.category.rawValue)  \(entry.message)"
    }

    /// `DateFormatter` is reusable and thread-safe for format operations.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

import Foundation
import Observability
import Observation
import Persistence

// MARK: - HistoryViewModel

/// The History destination's rows, its search and its debounce (ADR-094).
///
/// Owned by `LibraryViewModel` and rendered by `HistoryView`. The search here
/// is deliberately its own state: `query` never reads or writes the library's
/// `searchQuery`, so a filter typed on History cannot leak into Songs and a
/// library filter cannot leak in here. The 250 ms debounce mirrors the
/// library's, and a keystroke here reloads this list only.
@Observable
@MainActor
public final class HistoryViewModel {
    // MARK: - State

    /// One row per play, newest first.
    public private(set) var rows: [PlayHistoryRow] = [] {
        didSet { self.rowsVersion &+= 1 }
    }

    /// Moves on every write to `rows`, so `HistoryTable` walks the rows only
    /// when they changed (#450, #455).
    public private(set) var rowsVersion = 0
    /// `true` from the first load request until the first rows arrive.
    public private(set) var isLoading = false
    /// `true` once any load has completed, so an empty list reads as "no
    /// plays yet" rather than "not loaded yet".
    public private(set) var hasLoaded = false

    /// The text in the search field while History is showing. Writes are
    /// debounced into ``debouncedQuery``; the view observes on that.
    public var query = "" {
        didSet {
            guard self.query != oldValue else { return }
            self.scheduleDebounce()
        }
    }

    /// `query` as of 250 ms after the last keystroke. The observation task is
    /// keyed on this, so two keystrokes inside the window cost one load.
    public private(set) var debouncedQuery = ""

    // MARK: - Dependencies

    private let repository: PlayHistoryRepository
    private let trackRepository: TrackRepository
    private let log = AppLogger.make(.ui)
    /// The pending settle of `query` into `debouncedQuery`, nil when none is
    /// pending. Internal so a test can await it instead of sleeping past it
    /// (the bounded-waits rule in `docs/GOTCHAS.md`).
    @ObservationIgnored var debounceTask: Task<Void, any Error>?

    // MARK: - Init

    /// `repository` reads the plays; `trackRepository` resolves a play back
    /// to its song when an action needs one.
    public init(repository: PlayHistoryRepository, trackRepository: TrackRepository) {
        self.repository = repository
        self.trackRepository = trackRepository
    }

    // MARK: - Loading

    /// One read of the current `debouncedQuery`. `observe()` is what the view
    /// runs; this is for callers that want the rows once, and for tests.
    public func load() async {
        self.isLoading = self.rows.isEmpty
        do {
            self.rows = try await self.repository.recent(matching: self.debouncedQuery)
        } catch {
            self.log.error("history.load.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
        self.hasLoaded = true
    }

    /// Streams the rows for the current `debouncedQuery` until the calling
    /// task is cancelled: the first emission is the current list, and every
    /// later one is a play that finished while the page was open. Run it from
    /// a `.task(id: vm.debouncedQuery)` so a new query restarts it and leaving
    /// the page ends it.
    public func observe() async {
        self.isLoading = self.rows.isEmpty
        do {
            for try await rows in await self.repository.observeRecent(matching: self.debouncedQuery) {
                self.rows = rows
                self.isLoading = false
                self.hasLoaded = true
            }
        } catch is CancellationError {
            // The page went away, or the query moved on.
        } catch {
            self.log.error("history.observe.failed", ["error": String(reflecting: error)])
            self.isLoading = false
            self.hasLoaded = true
        }
    }

    /// Drops the query without waiting for the debounce, for the moments
    /// navigation clears it: the next observation runs on an empty term.
    public func clearQuery() {
        self.debounceTask?.cancel()
        self.query = ""
        self.debouncedQuery = ""
    }

    // MARK: - Rows to songs

    /// The row for a play, for the table's menu and double-click.
    public func row(forPlayID playID: Int64) -> PlayHistoryRow? {
        self.rows.first { $0.playID == playID }
    }

    /// The song a play was of, read fresh so an action gets current tags,
    /// or nil, logged, when the song row is gone.
    public func track(forPlayID playID: Int64) async -> Track? {
        guard let row = self.row(forPlayID: playID) else { return nil }
        do {
            return try await self.trackRepository.fetch(id: row.trackID)
        } catch {
            self.log.warning("history.track.fetchFailed", [
                "playID": playID,
                "trackID": row.trackID,
                "error": String(reflecting: error),
            ])
            return nil
        }
    }

    // MARK: - Debounce

    private func scheduleDebounce() {
        self.debounceTask?.cancel()
        self.debounceTask = Task { [weak self] in
            try await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.debouncedQuery = self.query
        }
    }
}

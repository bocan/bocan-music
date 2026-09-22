import Foundation
import Observability
import Observation
import Persistence

// MARK: - HistoryViewModel

/// The History destination's rows, its search, its source filter and its
/// paging (ADR-094).
///
/// Owned by `LibraryViewModel` and rendered by `HistoryView`. The search here
/// is deliberately its own state: `query` never reads or writes the library's
/// `searchQuery`, so a filter typed on History cannot leak into Songs and a
/// library filter cannot leak in here. The 250 ms debounce mirrors the
/// library's, and a keystroke here reloads this list only.
///
/// The list is a window: the newest ``pageSize`` rows, widened a page at a
/// time by ``loadMore()`` as the table nears its end. One observation covers
/// the whole window, so a play that finishes, or a re-match that links old
/// listens, lands in place without a reload.
@Observable
@MainActor
public final class HistoryViewModel {
    // MARK: - Types

    /// Everything the observation depends on. The view keys its task on
    /// this, so a change to any part restarts the stream and leaving the
    /// page ends it.
    public struct ObservationKey: Hashable, Sendable {
        public let query: String
        public let source: PlayHistoryRepository.SourceFilter
        public let pages: Int
    }

    /// Rows per page. Two thousand keeps a snapshot apply well inside the
    /// budget #450 measured, and covers the maintainer's local record in
    /// one page and the matched import in a dozen.
    public static let pageSize = 2000

    // MARK: - State

    /// Listens, newest first, up to the current window.
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

    /// `query` as of 250 ms after the last keystroke. A new term starts the
    /// window over from the newest rows.
    public private(set) var debouncedQuery = "" {
        didSet {
            guard self.debouncedQuery != oldValue else { return }
            self.pages = 1
        }
    }

    /// Which sources to list. A change starts the window over.
    public var sourceFilter: PlayHistoryRepository.SourceFilter = .all {
        didSet {
            guard self.sourceFilter != oldValue else { return }
            self.pages = 1
        }
    }

    /// How many pages the window currently spans.
    public private(set) var pages = 1

    /// The window's row cap.
    public var limit: Int {
        Self.pageSize * self.pages
    }

    /// `true` while the last load filled the window to its cap, so there may
    /// be older rows past it.
    public var hasMore: Bool {
        self.rows.count >= self.limit
    }

    /// What the view keys its observation task on: the debounced query, the
    /// source filter and the page count together.
    public var observationKey: ObservationKey {
        ObservationKey(query: self.debouncedQuery, source: self.sourceFilter, pages: self.pages)
    }

    // MARK: - Dependencies

    private let repository: PlayHistoryRepository
    private let trackRepository: TrackRepository
    private let log = AppLogger.make(.ui)
    /// The pending settle of `query` into `debouncedQuery`, nil when none is
    /// pending. Internal so a test can await it instead of sleeping past it
    /// (the bounded-waits rule in `docs/GOTCHAS.md`).
    @ObservationIgnored var debounceTask: Task<Void, any Error>?

    // MARK: - Init

    /// `repository` reads the listens; `trackRepository` resolves a row back
    /// to its song when an action needs one.
    public init(repository: PlayHistoryRepository, trackRepository: TrackRepository) {
        self.repository = repository
        self.trackRepository = trackRepository
    }

    // MARK: - Loading

    /// One read of the current window. `observe()` is what the view runs;
    /// this is for callers that want the rows once, and for tests.
    public func load() async {
        self.isLoading = self.rows.isEmpty
        do {
            self.rows = try await self.repository.recent(
                limit: self.limit, matching: self.debouncedQuery, source: self.sourceFilter
            )
        } catch {
            self.log.error("history.load.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
        self.hasLoaded = true
    }

    /// Streams the current window until the calling task is cancelled: the
    /// first emission is the current list, and every later one is a change
    /// to a listed table. Run it from a `.task(id: vm.observationKey)` so a
    /// new query, source or page restarts it and leaving the page ends it.
    public func observe() async {
        self.isLoading = self.rows.isEmpty
        do {
            let stream = await self.repository.observeRecent(
                limit: self.limit, matching: self.debouncedQuery, source: self.sourceFilter
            )
            for try await rows in stream {
                self.rows = rows
                self.isLoading = false
                self.hasLoaded = true
            }
        } catch is CancellationError {
            // The page went away, or the window moved on.
        } catch {
            self.log.error("history.observe.failed", ["error": String(reflecting: error)])
            self.isLoading = false
            self.hasLoaded = true
        }
    }

    /// Widens the window by one page, when the last load filled it.
    public func loadMore() {
        guard self.hasMore else { return }
        self.pages += 1
    }

    /// Drops the query without waiting for the debounce, for the moments
    /// navigation clears it: the next observation runs on an empty term.
    public func clearQuery() {
        self.debounceTask?.cancel()
        self.query = ""
        self.debouncedQuery = ""
    }

    // MARK: - Rows to songs

    /// The row for a listen, for the table's menu and double-click.
    public func row(forKey key: PlayHistoryRow.Key) -> PlayHistoryRow? {
        self.rows.first { $0.id == key }
    }

    /// The song a listen was of, read fresh so an action gets current tags,
    /// or nil, logged, when the song row is gone.
    public func track(forKey key: PlayHistoryRow.Key) async -> Track? {
        guard let row = self.row(forKey: key) else { return nil }
        do {
            return try await self.trackRepository.fetch(id: row.trackID)
        } catch {
            self.log.warning("history.track.fetchFailed", [
                "source": key.source.rawValue,
                "rowID": key.rowID,
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

import Foundation
import Library
import Observability
import Persistence

// MARK: - Load state

/// One report's lifecycle in a Deep Dive tab.
public enum DeepDiveState<Report: Sendable & Equatable>: Equatable {
    case idle
    case loading
    /// MusicBrainz answered "slow down"; waiting before attempt `attempt` of `of`.
    case retrying(attempt: Int, of: Int)
    case loaded(Report)
    case failed(DeepDiveError)
}

// MARK: - Retry policy

/// What a Deep Dive does when MusicBrainz answers 503 "slow down": wait
/// 1.5 s, 3 s, then 10 s between fresh attempts before giving up.
public enum DeepDiveRetry {
    /// Waits between attempts, in order; the count is the number of retries.
    public static let delays: [Duration] = [.seconds(1.5), .seconds(3), .seconds(10)]

    /// Runs `attempt`; on `DeepDiveError.rateLimited` waits each delay in
    /// turn (reporting the upcoming attempt number to `onRetry`) and tries
    /// again. The last failure propagates; cancellation stops the wait.
    @MainActor
    static func run<R: Sendable>(
        delays: [Duration],
        onRetry: (Int) -> Void,
        attempt: () async throws -> R
    ) async throws -> R {
        var used = 0
        while true {
            do {
                return try await attempt()
            } catch DeepDiveError.rateLimited where used < delays.count {
                onRetry(used + 1)
                try await Task.sleep(for: delays[used])
                used += 1
            }
        }
    }
}

// MARK: - Base view model

/// Drives one report: load with retry, expose the state, swap in a report.
/// The three concrete models below only differ in which service call they
/// wrap.
@MainActor
public class DeepDiveReportViewModel<Report: Sendable & Equatable>: ObservableObject {
    @Published public private(set) var state: DeepDiveState<Report> = .idle

    private let fetch: @Sendable (_ forceRefresh: Bool) async throws -> Report
    private let delays: [Duration]
    private let category: String
    private var task: Task<Void, Never>?
    let log = AppLogger.make(.ui)

    init(
        category: String,
        delays: [Duration] = DeepDiveRetry.delays,
        fetch: @escaping @Sendable (_ forceRefresh: Bool) async throws -> Report
    ) {
        self.category = category
        self.delays = delays
        self.fetch = fetch
    }

    public func load(forceRefresh: Bool = false) {
        self.task?.cancel()
        self.state = .loading
        self.task = Task { [fetch, delays] in
            do {
                let report = try await DeepDiveRetry.run(
                    delays: delays,
                    onRetry: { self.state = .retrying(attempt: $0, of: delays.count) },
                    attempt: { try await fetch(forceRefresh) }
                )
                guard !Task.isCancelled else { return }
                self.state = .loaded(report)
            } catch is CancellationError {
                return
            } catch let error as DeepDiveError {
                guard !Task.isCancelled else { return }
                self.state = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                self.log.error("deepdive.\(self.category).failed", ["error": String(reflecting: error)])
                self.state = .failed(.notFound)
            }
        }
    }

    /// Shows `report` without fetching: a confirmed report, or a test fixture.
    func show(_ report: Report) {
        self.task?.cancel()
        self.state = .loaded(report)
    }
}

// MARK: - Artist

@MainActor
public final class DeepDiveArtistViewModel: DeepDiveReportViewModel<ArtistReport> {
    private let service: DeepDiveService

    public init(service: DeepDiveService, artistID: Int64, delays: [Duration] = DeepDiveRetry.delays) {
        self.service = service
        super.init(category: "artist", delays: delays) { try await service.artistReport(artistID: artistID, forceRefresh: $0) }
    }

    /// Persists the guessed id shown in the loaded report (#413).
    public func confirmMBID() {
        guard case let .loaded(report) = self.state, report.mbidGuessed else { return }
        Task { [service] in
            do {
                try await self.show(service.confirmArtistMBID(report: report))
            } catch {
                self.log.error("deepdive.artist.confirm.failed", ["error": String(reflecting: error)])
            }
        }
    }
}

// MARK: - Track

@MainActor
public final class DeepDiveTrackViewModel: DeepDiveReportViewModel<TrackReport> {
    private let service: DeepDiveService
    private let saver: (any DeepDiveTagSaving)?

    public init(
        service: DeepDiveService,
        trackID: Int64,
        saver: (any DeepDiveTagSaving)? = nil,
        delays: [Duration] = DeepDiveRetry.delays
    ) {
        self.service = service
        self.saver = saver
        super.init(category: "track", delays: delays) { try await service.trackReport(trackID: trackID, forceRefresh: $0) }
    }

    /// True when a guessed match could be written to the file's tags here.
    public var canSaveToTags: Bool {
        self.saver != nil
    }

    /// Writes the guessed recording id into the file's tags.
    public func saveMatchToTags() {
        guard case let .loaded(report) = self.state, report.mbidGuessed, let saver else { return }
        Task { [service] in
            do {
                try await self.show(service.confirmTrackMatch(report: report, saver: saver))
            } catch {
                self.log.error("deepdive.track.saveToTags.failed", ["error": String(reflecting: error)])
            }
        }
    }
}

// MARK: - Album

@MainActor
public final class DeepDiveAlbumViewModel: DeepDiveReportViewModel<AlbumReport> {
    private let service: DeepDiveService
    private let saver: (any DeepDiveTagSaving)?

    public init(
        service: DeepDiveService,
        albumID: Int64,
        saver: (any DeepDiveTagSaving)? = nil,
        delays: [Duration] = DeepDiveRetry.delays
    ) {
        self.service = service
        self.saver = saver
        super.init(category: "album", delays: delays) { try await service.albumReport(albumID: albumID, forceRefresh: $0) }
    }

    /// True when a guessed match could be written to the album's files here.
    public var canSaveToTags: Bool {
        self.saver != nil
    }

    /// Writes the guessed release-group id into the tags of every track of
    /// the album, one edit transaction.
    public func saveMatchToTags() {
        guard case let .loaded(report) = self.state, report.mbidGuessed, let saver else { return }
        Task { [service] in
            do {
                let outcome = try await service.confirmAlbumMatch(report: report, saver: saver)
                self.log.info("deepdive.album.saveToTags", ["tracks": outcome.tracksWritten])
                self.show(outcome.report)
            } catch {
                self.log.error("deepdive.album.saveToTags.failed", ["error": String(reflecting: error)])
            }
        }
    }
}

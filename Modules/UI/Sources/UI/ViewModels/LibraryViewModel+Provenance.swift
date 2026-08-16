import AudioEngine
import Foundation
import Observability
import Persistence

// MARK: - ProvenanceBatchProgress

/// Progress snapshot for a running or completed transcode-detection batch
/// (ADR-075 slice 3).
public struct ProvenanceBatchProgress: Equatable, Sendable {
    /// Files processed so far, including failures.
    public let done: Int
    /// Files the batch set out to analyse.
    public let total: Int
    /// Files that could not be analysed (unreadable, undecodable).
    public let failed: Int
    /// Files newly flagged as suspected transcodes in this run.
    public let suspected: Int

    /// True once every file has been processed.
    public var isComplete: Bool {
        self.done == self.total
    }

    /// Files that produced a verdict.
    public var succeeded: Int {
        self.done - self.failed
    }
}

// MARK: - Provenance batch (ADR-075 slice 3)

/// The transcode-detection batch job: sequential decode-and-score over every
/// lossless track still needing a verdict, following the Compute Missing
/// ReplayGain pattern (background run, live progress, toast on completion).
public extension LibraryViewModel {
    /// Starts the transcode-detection batch at utility QoS: a large library
    /// is hours of decoding, and that is fine because verdicts persist and
    /// the analysis never competes with playback for the interactive tiers.
    /// A stale completed banner is cleared and a fresh run started.
    ///
    /// `announce` controls the where-to-watch toasts: the Tools menu keeps it
    /// on so the click visibly does something; the Library Summary pane's own
    /// button passes false because the progress appears right under it.
    func startProvenanceAnalysis(announce: Bool = true) {
        if let progress = self.provenanceProgress {
            guard progress.isComplete else {
                if announce {
                    self.showToast(ToastMessage(
                        text: L10n.string("Provenance analysis is already running. See Tools → Library Summary → Audio Quality."),
                        kind: .info
                    ))
                }
                return
            }
            self.provenanceProgress = nil
        }
        self.provenanceTask = Task(priority: .utility) { await self.analyseProvenance(announce: announce) }
    }

    /// Requests cancellation; the batch stops once the file in flight winds
    /// down. Verdicts already written are kept.
    func cancelProvenanceAnalysis() {
        self.provenanceTask?.cancel()
    }

    /// Analyses every lossless-claiming track still needing a verdict, one
    /// file at a time, writing each verdict as it lands. Public so tests can
    /// await the whole run; app code goes through ``startProvenanceAnalysis(announce:)``.
    func analyseProvenance(announce: Bool = false) async {
        guard self.provenanceProgress == nil else { return } // already running
        let log = AppLogger.make(.audio)
        let repo = TrackRepository(database: self.database)
        let start = Date()
        let total: Int
        do {
            total = try await repo.countNeedingProvenance()
        } catch {
            log.error("provenance.batch.countFailed", ["error": String(reflecting: error)])
            return
        }
        guard total > 0 else {
            self.showToast(ToastMessage(
                text: L10n.string("No lossless tracks need provenance analysis"),
                kind: .info
            ))
            return
        }
        if announce {
            self.showToast(ToastMessage(
                text: L10n.string("Analysing \(total) lossless files. Watch progress in Tools → Library Summary → Audio Quality."),
                kind: .info
            ))
        }
        log.debug("provenance.batch.start", ["total": total])
        self.provenanceProgress = ProvenanceBatchProgress(done: 0, total: total, failed: 0, suspected: 0)

        let tally = await self.runProvenanceLoop(repo: repo, total: total, log: log)

        log.debug("provenance.batch.end", [
            "done": tally.done,
            "failed": tally.failed,
            "suspected": tally.suspected,
            "stopped": tally.stopped,
            "ms": -start.timeIntervalSinceNow * 1000,
        ])
        if tally.stopped {
            self.provenanceProgress = nil
            self.showToast(ToastMessage(
                text: L10n.string("Provenance analysis stopped: \(tally.done) of \(total) files analysed"),
                kind: .info
            ))
        } else {
            self.showToast(ToastMessage(text: Self.completionToast(tally), kind: .success))
        }
    }
}

private extension LibraryViewModel {
    /// Counters for one batch run. `stopped` covers user cancellation and an
    /// unexpected paging failure; either way the run ended early and the
    /// banner is torn down instead of lingering incomplete.
    struct ProvenanceTally {
        var done = 0
        var failed = 0
        var suspected = 0
        var stopped = false
    }

    /// Outcome of analysing one file off the main actor.
    enum ProvenanceOutcome {
        case verdict(ProvenanceVerdict)
        case failed
        case cancelled
    }

    /// Pages through the candidates by id cursor, one file at a time. The
    /// cursor also steps past failed files, so one undecodable file can never
    /// wedge the batch into refetching itself forever.
    func runProvenanceLoop(repo: TrackRepository, total: Int, log: AppLogger) async -> ProvenanceTally {
        var tally = ProvenanceTally()
        var cursor: Int64 = 0
        pages: while true {
            let page: [Track]
            do {
                page = try await repo.fetchNeedingProvenance(limit: 32, afterID: cursor)
            } catch {
                log.error("provenance.batch.pageFailed", ["error": String(reflecting: error)])
                tally.stopped = true
                break
            }
            guard !page.isEmpty else { break }
            for track in page {
                guard let trackID = track.id else { continue }
                cursor = max(cursor, trackID)
                if Task.isCancelled {
                    tally.stopped = true
                    break pages
                }
                switch await Self.analyzeTrackProvenance(track) {
                case .cancelled:
                    tally.stopped = true
                    break pages

                case let .verdict(verdict):
                    if await self.storeVerdict(verdict, trackID: trackID, repo: repo, log: log) {
                        if verdict.suspected { tally.suspected += 1 }
                    } else {
                        tally.failed += 1
                    }
                    tally.done += 1

                case .failed:
                    tally.failed += 1
                    tally.done += 1
                }
                self.provenanceProgress = ProvenanceBatchProgress(
                    done: tally.done,
                    total: total,
                    failed: tally.failed,
                    suspected: tally.suspected
                )
            }
        }
        return tally
    }

    /// Writes one verdict; returns false (and logs) when the write fails.
    func storeVerdict(
        _ verdict: ProvenanceVerdict,
        trackID: Int64,
        repo: TrackRepository,
        log: AppLogger
    ) async -> Bool {
        do {
            try await repo.setProvenance(
                trackID: trackID,
                suspected: verdict.suspected,
                confidence: verdict.confidence,
                shelfHz: verdict.shelfFrequencyHz,
                analysedAt: Int64(verdict.analysedAt.timeIntervalSince1970)
            )
            return true
        } catch {
            log.error("provenance.batch.updateFailed", ["error": String(reflecting: error)])
            return false
        }
    }

    /// Runs off the main actor on the cooperative pool: resolves the
    /// security-scoped bookmark, decodes the sample windows, and scores them.
    /// Mirrors the ReplayGain batch's per-track helper.
    nonisolated static func analyzeTrackProvenance(_ track: Track) async -> ProvenanceOutcome {
        let log = AppLogger.make(.audio)
        do {
            let url: URL
            if let bookmarkData = track.fileBookmark {
                url = try BookmarkBlob(data: bookmarkData).resolve()
            } else {
                guard let raw = URL(string: track.fileURL) else { throw URLError(.badURL) }
                url = raw
            }
            defer { url.stopAccessingSecurityScopedResource() }
            return try await .verdict(ProvenanceAnalyzer.analyze(url: url))
        } catch is CancellationError {
            return .cancelled
        } catch {
            log.warning("provenance.batch.trackFailed", [
                "url": track.fileURL,
                "error": String(reflecting: error),
            ])
            return .failed
        }
    }

    /// "Provenance analysis complete: N analysed, M suspected(, K failed)".
    static func completionToast(_ tally: ProvenanceTally) -> String {
        let base = L10n.string(
            "Provenance analysis complete: \(tally.done - tally.failed) analysed, \(tally.suspected) suspected"
        )
        return tally.failed > 0 ? L10n.string("\(base), \(tally.failed) failed") : base
    }
}

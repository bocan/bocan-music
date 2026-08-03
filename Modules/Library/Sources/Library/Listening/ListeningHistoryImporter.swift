import Foundation
import Observability
import Persistence

/// Imports a Last.fm export end to end (phase 25-1): parse, idempotent batch
/// insert, one re-match pass, and a summary for the completion toast. Local
/// counters are never touched; see `ListenImportRepository`.
public struct ListeningHistoryImporter: Sendable {
    // MARK: - Properties

    private let repository: ListenImportRepository
    private let log = AppLogger.make(.library)

    /// Rows inserted per transaction; keeps a 200k-scrobble export from
    /// holding one giant write lock.
    private static let batchSize = 2000

    // MARK: - Init

    /// Creates an importer writing through `database`.
    public init(database: Database) {
        self.repository = ListenImportRepository(database: database)
    }

    // MARK: - Summary

    /// What one import run did, in toast-ready numbers.
    public struct Summary: Equatable, Sendable {
        /// Valid listens found in the file.
        public let parsed: Int
        /// Rows the parser had to skip.
        public let malformedRows: Int
        /// Rows new to the store (the rest were already imported).
        public let inserted: Int
        /// Rows that gained a library match this run.
        public let newlyMatched: Int
        /// Matched rows dropped as echoes of local plays.
        public let overlapRemoved: Int
        /// Store totals after the run.
        public let totalStored: Int
        /// Matched totals after the run.
        public let totalMatched: Int

        /// Rows in the file that were already imported previously.
        public var duplicates: Int {
            self.parsed - self.inserted
        }
    }

    // MARK: - Import

    /// Reads, parses, stores, and matches the export at `url`.
    ///
    /// The URL comes from an open panel, whose grant covers this one-shot
    /// read; no bookmark is minted.
    public func importExport(at url: URL) async throws -> Summary {
        let start = Date()
        self.log.info("listens.import.start", ["file": url.lastPathComponent])
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LibraryError.listenExportUnreadable(reason: String(reflecting: error))
        }
        let parsed = try LastFMExportParser.parse(text)

        var inserted = 0
        var cursor = 0
        while cursor < parsed.listens.count {
            try Task.checkCancellation()
            let upper = min(cursor + Self.batchSize, parsed.listens.count)
            inserted += try await self.repository.insert(Array(parsed.listens[cursor ..< upper]))
            cursor = upper
        }

        let rematch = try await self.repository.rematch()
        let counts = try await self.repository.counts()
        let summary = Summary(
            parsed: parsed.listens.count,
            malformedRows: parsed.malformedRows,
            inserted: inserted,
            newlyMatched: rematch.newlyMatched,
            overlapRemoved: rematch.overlapRemoved,
            totalStored: counts.total,
            totalMatched: counts.matched
        )
        self.log.info("listens.import.end", [
            "parsed": summary.parsed,
            "malformed": summary.malformedRows,
            "inserted": summary.inserted,
            "matched": summary.newlyMatched,
            "overlapRemoved": summary.overlapRemoved,
            "ms": -start.timeIntervalSinceNow * 1000,
        ])
        return summary
    }
}

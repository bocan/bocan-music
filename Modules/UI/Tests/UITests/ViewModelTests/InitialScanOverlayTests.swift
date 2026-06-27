import Foundation
import Testing

// MARK: - InitialScanOverlayTests

/// The full-screen scan progress overlay (`isInitialScan`) must only appear for a
/// genuine first-run, empty-library scan. It used to be keyed off the Songs view's
/// loaded rows (`tracks.rows.isEmpty`), which is empty whenever the app relaunches
/// into a playlist/album/folder/smart-playlist view (those detail views self-load
/// and never populate `tracks.rows`). That false positive overlaid the scan pane
/// over already-populated content on every routine startup rescan. The flag must
/// instead reflect the real library track count.
@Suite("Initial scan overlay")
struct InitialScanOverlayTests {
    private func scanningSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/ViewModels/LibraryViewModel+Scanning.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("isInitialScan is derived from the library track count, not the loaded view rows")
    func initialScanKeysOffLibraryCount() throws {
        let source = try self.scanningSource()
        // The decision must come from a real library count query.
        #expect(
            source.contains("TrackRepository(database: self.database).count()"),
            "isInitialScan must be derived from the library track count"
        )
        #expect(
            source.contains("self.isInitialScan = trackCount == 0"),
            "isInitialScan must be true only when the library has zero tracks"
        )
        // The old, buggy heuristic must be gone.
        #expect(
            !source.contains("self.isInitialScan = self.tracks.rows.isEmpty"),
            "isInitialScan must not be keyed off the loaded Songs view rows"
        )
    }
}

// MARK: - PostScanReloadGateTests

/// The post-scan data reload (Albums/Artists/active destination) must be gated on
/// the scan having actually changed something. The routine quick rescan fired on
/// every launch reports an all-zero summary on a stable library; reloading anyway
/// tore the already-populated Songs list down to a spinner and rebuilt it with
/// identical rows -- a visible "vanish then reappear" flash on every startup.
@Suite("Post-scan reload gate")
struct PostScanReloadGateTests {
    private func scanningSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/ViewModels/LibraryViewModel+Scanning.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The post-scan reload only runs when the scan changed something")
    func reloadIsGatedOnSummaryChanges() throws {
        let source = try self.scanningSource()
        // The gate must be derived from the finished summary's counts.
        #expect(
            source.contains("summary.inserted > 0")
                && source.contains("summary.updated > 0")
                && source.contains("summary.removed > 0"),
            "the post-scan reload must be gated on the summary's inserted/updated/removed counts"
        )
        // The post-scan reload must sit inside the change-gated branch. Scope the
        // search to the source after the gate (loadCurrentDestination() is also
        // called by other paths earlier in the file).
        guard let gateRange = source.range(of: "let changed = summary.inserted") else {
            Issue.record("the `changed` gate must exist")
            return
        }
        let afterGate = source[gateRange.upperBound...]
        let branchIndex = afterGate.range(of: "if changed {")
        let reloadIndex = afterGate.range(of: "await self.loadCurrentDestination()")
        #expect(branchIndex != nil, "the post-scan reload must live in an `if changed {` branch")
        if let branchIndex, let reloadIndex {
            #expect(
                branchIndex.lowerBound < reloadIndex.lowerBound,
                "loadCurrentDestination() must run inside the `if changed {` branch"
            )
        }
    }
}

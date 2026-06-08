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

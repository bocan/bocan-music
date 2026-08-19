import Foundation
import Observability
import Testing
@testable import UI

@Suite("DiagnosticsExporter")
struct DiagnosticsExporterTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `LogEntry`'s memberwise init is internal to Observability, so entries
    /// are minted through a real (throwaway) store.
    private func makeEntry(_ message: String) -> [LogEntry] {
        let store = LogStore(capacity: 4)
        store.record(level: .info, category: .ui, message: message)
        return store.snapshot()
    }

    @Test("export writes a non-empty zip at the destination")
    func exportWritesZip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("out.zip")

        let reports = dir.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try Data("report body".utf8).write(to: reports.appendingPathComponent("2026-06-30.json"))

        try DiagnosticsExporter.export(
            DiagnosticsExporter.Inputs(
                logs: self.makeEntry("engine.start"),
                reportsDirectory: reports,
                appVersion: "2.8.0 (167)",
                osVersion: "macOS 15.6"
            ),
            to: destination
        )

        let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int ?? 0
        #expect(size > 0, "the zip must actually contain the bundle")
        // Zip magic: PK\x03\x04.
        let head = try FileHandle(forReadingFrom: destination).read(upToCount: 4)
        #expect(head == Data([0x50, 0x4B, 0x03, 0x04]))
    }

    @Test("export succeeds without a reports directory and overwrites an existing file")
    func exportWithoutReportsOverwrites() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("out.zip")
        try Data("stale".utf8).write(to: destination)

        try DiagnosticsExporter.export(
            DiagnosticsExporter.Inputs(
                logs: [],
                reportsDirectory: dir.appendingPathComponent("missing", isDirectory: true),
                appVersion: "2.8.0 (167)",
                osVersion: "macOS 15.6"
            ),
            to: destination
        )

        let head = try FileHandle(forReadingFrom: destination).read(upToCount: 4)
        #expect(head == Data([0x50, 0x4B, 0x03, 0x04]), "the stale file must be replaced by a real zip")
    }
}

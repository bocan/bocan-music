import Foundation
import Observability

// MARK: - DiagnosticsExporter

/// Builds the "Export Diagnostics…" bundle (Settings > Advanced): a zip
/// containing the session's captured log lines, any MetricKit diagnostic
/// reports, and an app/OS info sheet — everything a bug report needs in one
/// attachable file. Pure file operations; the view supplies the inputs so
/// this stays testable host-less.
enum DiagnosticsExporter {
    struct Inputs {
        /// Captured session log entries (from `LogStore.shared.snapshot()`).
        var logs: [LogEntry]
        /// The MetricKit reports directory; skipped when nil or absent.
        var reportsDirectory: URL?
        /// "2.8.0 (167)" — version and build from the main bundle.
        var appVersion: String
        /// `ProcessInfo` OS version string.
        var osVersion: String
    }

    /// Assembles the bundle in a temp folder, zips it via the file
    /// coordinator (sandbox-safe: no external `zip` binary), and moves the
    /// archive to `destination`, replacing any existing file the save panel
    /// already confirmed overwriting.
    static func export(_ inputs: Inputs, to destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("BocanDiagnostics-\(UUID().uuidString)", isDirectory: true)
        let bundleDir = staging.appendingPathComponent("BocanDiagnostics", isDirectory: true)
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try Self.renderInfo(inputs).write(
            to: bundleDir.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8
        )
        try Self.renderLogs(inputs.logs).write(
            to: bundleDir.appendingPathComponent("logs.txt"), atomically: true, encoding: .utf8
        )
        if let reports = inputs.reportsDirectory, fm.fileExists(atPath: reports.path) {
            try fm.copyItem(
                at: reports, to: bundleDir.appendingPathComponent("diagnostics", isDirectory: true)
            )
        }

        let zipped = try Self.zip(directory: bundleDir)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: zipped, to: destination)
    }

    // MARK: - Pieces

    private static func renderInfo(_ inputs: Inputs) -> String {
        """
        Bòcan diagnostics bundle
        Generated: \(ISO8601DateFormatter().string(from: Date()))
        App version: \(inputs.appVersion)
        macOS: \(inputs.osVersion)
        Log lines: \(inputs.logs.count)
        """
    }

    private static func renderLogs(_ logs: [LogEntry]) -> String {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return logs
            .map { "\(stamp.string(from: $0.timestamp)) [\($0.level)] \($0.category.rawValue): \($0.message)" }
            .joined(separator: "\n")
    }

    /// Zips `directory` using `NSFileCoordinator`'s `.forUploading` option —
    /// the sandbox-safe archive path (the coordinator produces a zip in its
    /// own temp zone; copy it out before the accessor returns and it is
    /// reclaimed). Throws the coordinator's error, or a fallback if the
    /// accessor never ran.
    private static func zip(directory: URL) throws -> URL {
        var coordinatorError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(
            readingItemAt: directory, options: .forUploading, error: &coordinatorError
        ) { zippedURL in
            do {
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).zip")
                try FileManager.default.copyItem(at: zippedURL, to: out)
                result = .success(out)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try result.get()
    }
}

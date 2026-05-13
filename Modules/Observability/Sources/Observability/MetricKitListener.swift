import MetricKit
import os

// Subscribes to `MXMetricManager` and forwards metric / diagnostic payloads
// to `AppLogger(.app)` and to disk at `~/Library/Logs/Bocan/diagnostics/`.
//
// Instantiate once at app launch:
// ```swift
// MetricKitListener.shared.start()
// ```
// `start()` is consent-gated: it is a no-op unless the user has accepted via
// the first-launch banner or the Diagnostics settings toggle.
#if os(macOS)
    @MainActor
    public final class MetricKitListener: NSObject, MXMetricManagerSubscriber {
        public static let shared = MetricKitListener()

        // MARK: UserDefaults keys (public so the UI layer can use the same strings)

        /// `Bool` — `true` = user has granted consent to collect crash reports.
        public static let consentKey = "diagnostics.crashReportingConsented"
        /// `Bool` — `true` = we have already shown the consent prompt.
        public static let consentAskedKey = "diagnostics.consentAsked"

        private let log = AppLogger.make(.app)
        private var isSubscribed = false

        override private init() {}

        // MARK: - Lifecycle

        /// Subscribe to MetricKit if the user has granted consent.
        ///
        /// Safe to call multiple times — subsequent calls are no-ops when already
        /// subscribed.  Also a no-op when consent has not been granted.
        public func start() {
            guard UserDefaults.standard.bool(forKey: Self.consentKey) else {
                self.log.debug("metrickit.start_skipped_no_consent")
                return
            }
            guard !self.isSubscribed else { return }
            MXMetricManager.shared.add(self)
            self.isSubscribed = true
            self.log.info("metrickit.subscribed")
        }

        /// Unsubscribe from MetricKit payloads. Call when the user revokes consent
        /// or from `applicationWillTerminate`.
        public func stop() {
            guard self.isSubscribed else { return }
            MXMetricManager.shared.remove(self)
            self.isSubscribed = false
            self.log.info("metrickit.unsubscribed")
        }

        // MARK: - MXMetricManagerSubscriber

        /// MXMetricPayload is unavailable on macOS; only diagnostics are supported.
        public nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for payload in payloads {
                let data = payload.jsonRepresentation()
                let log = AppLogger.make(.app)
                let json = String(data: data, encoding: .utf8) ?? "<binary>"
                log.notice("metrickit.payload.diagnostics", ["json": json])
                Self.writePayload(data)
            }
        }

        // MARK: - Disk persistence

        /// `~/Library/Logs/Bocan/diagnostics/` — where report `.json` files live.
        public nonisolated static var reportsDirectory: URL {
            FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("Logs/Bocan/diagnostics")
        }

        /// Returns all `.json` report files in `reportsDirectory`, newest first.
        public nonisolated static func listReports() -> [URL] {
            let dir = Self.reportsDirectory
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            )) ?? []
            return files
                .filter { $0.pathExtension == "json" }
                .sorted {
                    let da = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                    let db = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                    return da > db
                }
        }

        /// Write a diagnostic payload to disk, redacting the user's home directory path.
        nonisolated static func writePayload(_ data: Data) {
            let dir = Self.reportsDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let file = dir.appendingPathComponent("\(name).json")
            var json = String(data: data, encoding: .utf8) ?? ""
            // Redact home directory path before writing (issue #209 §4).
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            json = json.replacingOccurrences(of: home, with: "~")
            try? json.write(to: file, atomically: true, encoding: .utf8)
            AppLogger.make(.app).info("metrickit.payload.written", ["file": file.lastPathComponent])
        }
    }
#endif

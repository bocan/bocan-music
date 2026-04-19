import MetricKit
import Testing
@testable import Observability

// MARK: - Redaction

@Suite("Redaction")
struct RedactionTests {
    @Test("sanitize replaces all known sensitive keys")
    func sanitizeSensitiveKeys() {
        let sensitive: [String: Any] = [
            "apiKey": "abc123",
            "token": "tok_xyz",
            "sessionKey": "sess",
            "password": "s3cr3t",
            "authorization": "Bearer xyz",
            "cookie": "session=1",
            "set-cookie": "id=2",
            "secret": "top",
            "refreshToken": "rt",
            "accessToken": "at",
        ]
        let result = Redaction.sanitize(sensitive)
        for key in sensitive.keys {
            #expect(result[key] == "<redacted>", "Expected \(key) to be redacted")
        }
    }

    @Test("sanitize preserves non-sensitive keys")
    func sanitizePreservesNonSensitiveKeys() {
        let fields: [String: Any] = [
            "format": "FLAC",
            "sampleRate": 44100,
            "duration": 3.14,
        ]
        let result = Redaction.sanitize(fields)
        #expect(result["format"] == "FLAC")
        #expect(result["sampleRate"] == "44100")
    }

    @Test("sanitize is case-insensitive for sensitive keys")
    func sanitizeCaseInsensitive() {
        let fields: [String: Any] = [
            "ApiKey": "should-be-redacted",
            "PASSWORD": "also-redacted",
        ]
        let result = Redaction.sanitize(fields)
        #expect(result["ApiKey"] == "<redacted>")
        #expect(result["PASSWORD"] == "<redacted>")
    }

    @Test("sanitize returns empty dict for empty input")
    func sanitizeEmpty() {
        let result = Redaction.sanitize([:])
        #expect(result.isEmpty)
    }
}

// MARK: - LogCategory

@Suite("LogCategory")
struct LogCategoryTests {
    @Test("all expected categories are present")
    func allCategoriesPresent() {
        let names = Set(LogCategory.allCases.map(\.rawValue))
        let expected: Set = [
            "app", "audio", "library", "metadata", "persistence",
            "ui", "network", "playback", "cast", "scrobble",
        ]
        #expect(names == expected)
    }

    @Test("rawValue matches case name")
    func rawValues() {
        for category in LogCategory.allCases {
            #expect(category.rawValue == "\(category)")
        }
    }
}

// MARK: - AppLogger

@Suite("AppLogger")
struct AppLoggerTests {
    @Test("make factory returns a logger that does not crash at any level")
    func makeFactoryAllLevels() {
        let log = AppLogger.make(.app)
        // These must not crash. OSLog messages are fire-and-forget;
        // we verify the format helper separately.
        log.trace("trace.event")
        log.debug("debug.event")
        log.info("info.event")
        log.notice("notice.event")
        log.warning("warning.event")
        log.error("error.event")
        log.fault("fault.event")
    }

    @Test("format produces stable key-sorted suffix")
    func formatSortedSuffix() {
        let log = AppLogger.make(.app)
        let result = log.format("msg", ["z": "last", "a": "first", "m": "mid"])
        // Keys must appear in alphabetical order
        #expect(result == "msg [a=first m=mid z=last]")
    }

    @Test("format with no fields returns plain message")
    func formatNoFields() {
        let log = AppLogger.make(.app)
        let result = log.format("plain message", [:])
        #expect(result == "plain message")
    }

    @Test("format redacts sensitive values in suffix")
    func formatRedactsSensitiveValues() {
        let log = AppLogger.make(.app)
        let result = log.format("auth.start", ["token": "abc", "user": "alice"])
        #expect(result.contains("token=<redacted>"))
        #expect(result.contains("user=alice"))
    }

    @Test("AppLogger is Sendable — usable from concurrent contexts")
    func sendable() async {
        let log = AppLogger.make(.audio)
        await withTaskGroup(of: Void.self) { group in
            for idx in 0 ..< 10 {
                group.addTask {
                    log.debug("concurrent.event", ["idx": idx])
                }
            }
        }
        // No crash == pass
    }
}

// MARK: - Telemetry

@Suite("Telemetry")
struct TelemetryTests {
    @Test("counter does not crash")
    func counterSmoke() {
        Telemetry.counter("test.counter", by: 3, tags: ["env": "test"])
    }

    @Test("timer end closure does not crash")
    func timerSmoke() {
        let end = Telemetry.timer("test.timer", tags: [:])
        end()
    }

    @Test("timer can be deferred")
    func timerDeferred() {
        let end = Telemetry.timer("test.timer.defer")
        do { end() }
        // No crash == pass
    }
}

// MARK: - MetricKitListener

#if os(macOS)
    @Suite("MetricKitListener")
    @MainActor
    struct MetricKitListenerTests {
        @Test("shared singleton is accessible")
        func sharedAccessible() {
            let listener = MetricKitListener.shared
            #expect(listener !== nil as AnyObject?)
        }

        @Test("start and stop do not crash")
        func startStop() {
            let listener = MetricKitListener.shared
            listener.start()
            listener.stop()
        }

        @Test("didReceive diagnostic payloads does not crash with empty array")
        func didReceiveDiagnosticPayloads() {
            let listener = MetricKitListener.shared
            let payloads: [MXDiagnosticPayload] = []
            listener.didReceive(payloads)
        }
    }
#endif

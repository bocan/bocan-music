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

    @Test("sanitize scrubs sensitive query params inside a URL value (#286)")
    func sanitizeScrubsURLQueryParams() {
        let fields: [String: Any] = [
            "url": "https://api.example.com/lookup?token=abc123&duration=259&salt=xyz",
        ]
        let result = Redaction.sanitize(fields)
        let sanitized = result["url"] ?? ""
        #expect(!sanitized.contains("abc123"), "token value must be scrubbed from URL")
        #expect(!sanitized.contains("xyz"), "salt value must be scrubbed from URL")
        #expect(sanitized.contains("token=<redacted>"))
        #expect(sanitized.contains("salt=<redacted>"))
        #expect(sanitized.contains("duration=259"), "non-sensitive param must be preserved")
    }

    @Test("scrubURLQueryParams scrubs Subsonic wire-format auth params")
    func scrubSubsonicWireParams() {
        let url = "https://music.example.com/rest/stream.view"
            + "?u=chris&t=0fd9a3f4c0de&s=ab12cd&v=1.16.1&c=bocan&f=json&id=42"
        let scrubbed = Redaction.scrubURLQueryParams(in: url)
        #expect(!scrubbed.contains("0fd9a3f4c0de"), "Subsonic auth token (t=) must be scrubbed")
        #expect(!scrubbed.contains("ab12cd"), "Subsonic salt (s=) must be scrubbed")
        #expect(!scrubbed.contains("chris"), "Subsonic username (u=) must be scrubbed")
        #expect(scrubbed.contains("t=<redacted>"))
        #expect(scrubbed.contains("s=<redacted>"))
        #expect(scrubbed.contains("u=<redacted>"))
        #expect(scrubbed.contains("v=1.16.1"), "non-sensitive params must be preserved")
        #expect(scrubbed.contains("id=42"))
    }

    @Test("scrubURLQueryParams scrubs Last.fm session key and signature")
    func scrubLastFmWireParams() {
        let url = "https://ws.audioscrobbler.com/2.0/"
            + "?method=track.love&sk=d580d57f32848f5d&api_sig=cafef00dba5eba11&api_key=0a1b2c3d&artist=Lankum&format=json"
        let scrubbed = Redaction.scrubURLQueryParams(in: url)
        #expect(!scrubbed.contains("d580d57f32848f5d"), "Last.fm session key (sk=) must be scrubbed")
        #expect(!scrubbed.contains("cafef00dba5eba11"), "Last.fm api_sig must be scrubbed")
        #expect(scrubbed.contains("sk=<redacted>"))
        #expect(scrubbed.contains("api_sig=<redacted>"))
        #expect(scrubbed.contains("api_key=<redacted>"))
        #expect(scrubbed.contains("method=track.love"), "non-sensitive params must be preserved")
        #expect(scrubbed.contains("artist=Lankum"))
    }

    @Test("sanitize scrubs auth params inside a reflected URLError string")
    func sanitizeScrubsReflectedErrorURL() {
        // String(reflecting:) of a URLError embeds the full failing URL; the
        // scrubber must still catch credential params inside that larger string.
        let reflected = "URLError(.timedOut, userInfo: [NSErrorFailingURLStringKey: "
            + "https://music.example.com/rest/stream.view?u=chris&t=0fd9a3f4c0de&s=ab12cd&id=42])"
        let result = Redaction.sanitize(["error": reflected])
        let value = result["error"] ?? ""
        #expect(!value.contains("0fd9a3f4c0de"), "auth token must not survive error reflection")
        #expect(!value.contains("ab12cd"), "salt must not survive error reflection")
        #expect(value.contains("t=<redacted>"))
        #expect(value.contains("s=<redacted>"))
    }

    @Test("scrubURLQueryParams leaves non-URL strings unchanged")
    func scrubURLQueryParamsNoop() {
        let plain = "just a plain log message"
        #expect(Redaction.scrubURLQueryParams(in: plain) == plain)
    }

    @Test("scrubURLQueryParams leaves safe params unchanged")
    func scrubURLQueryParamsSafePreserved() {
        let url = "https://example.com/lookup?format=json&duration=30"
        #expect(Redaction.scrubURLQueryParams(in: url) == url)
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
            "ui", "network", "playback", "podcasts", "scrobble", "subsonic",
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

        @Test("reportsDirectory URL contains expected path components")
        func reportsDirectoryComponents() {
            let dir = MetricKitListener.reportsDirectory
            #expect(dir.path.contains("Logs"))
            #expect(dir.path.contains("Bocan"))
            #expect(dir.path.contains("diagnostics"))
        }

        @Test("listReports returns only JSON files and exercises the sort closure")
        func listReportsFiltersAndSorts() throws {
            let dir = MetricKitListener.reportsDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let json1 = dir.appendingPathComponent("tip-a.json")
            let json2 = dir.appendingPathComponent("tip-b.json")
            let txt = dir.appendingPathComponent("tip-c.txt")
            defer {
                try? FileManager.default.removeItem(at: json1)
                try? FileManager.default.removeItem(at: json2)
                try? FileManager.default.removeItem(at: txt)
            }
            try "{}".write(to: json1, atomically: true, encoding: .utf8)
            try "{}".write(to: json2, atomically: true, encoding: .utf8)
            try "x".write(to: txt, atomically: true, encoding: .utf8)

            let reports = MetricKitListener.listReports()
            let names = reports.map(\.lastPathComponent)
            #expect(reports.allSatisfy { $0.pathExtension == "json" })
            #expect(names.contains("tip-a.json"))
            #expect(names.contains("tip-b.json"))
            #expect(!names.contains("tip-c.txt"))
        }

        @Test("writePayload creates a redacted JSON file discoverable via listReports")
        func writePayloadCreatesRedactedFile() {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let testJSON = "{\"path\": \"\(home)/test.flac\"}"
            let data = Data(testJSON.utf8)

            let before = Set(MetricKitListener.listReports().map(\.lastPathComponent))
            MetricKitListener.writePayload(data)
            let after = MetricKitListener.listReports()

            let newFiles = after.filter { !before.contains($0.lastPathComponent) }
            defer {
                for file in newFiles {
                    try? FileManager.default.removeItem(at: file)
                }
            }

            #expect(!newFiles.isEmpty, "writePayload should create a new file")
            if let written = newFiles.first,
               let content = try? String(contentsOf: written, encoding: .utf8) {
                #expect(!content.contains(home), "Home directory path should be redacted")
                #expect(content.contains("~"), "Home path should be replaced with ~")
            }
        }

        @Test("start subscribes when consent is granted and is idempotent")
        func startIdempotentWithConsent() {
            UserDefaults.standard.set(true, forKey: MetricKitListener.consentKey)
            defer {
                UserDefaults.standard.removeObject(forKey: MetricKitListener.consentKey)
                MetricKitListener.shared.stop()
            }
            MetricKitListener.shared.start()
            // Second call hits the already-subscribed guard — should be a no-op
            MetricKitListener.shared.start()
        }

        @Test("stop after subscribing does not crash; double-stop is idempotent")
        func stopIdempotentAfterSubscribe() {
            UserDefaults.standard.set(true, forKey: MetricKitListener.consentKey)
            defer { UserDefaults.standard.removeObject(forKey: MetricKitListener.consentKey) }
            MetricKitListener.shared.start()
            MetricKitListener.shared.stop()
            // Second stop hits the not-subscribed guard — should be a no-op
            MetricKitListener.shared.stop()
        }
    }
#endif

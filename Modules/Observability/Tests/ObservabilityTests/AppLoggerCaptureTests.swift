import Testing
@testable import Observability

/// Tests for the AppLogger -> LogStore tee introduced in Phase 20 step 4.
///
/// Each test injects an isolated `LogStore` instance so concurrent test suites
/// cannot pollute each other via `LogStore.shared`.
@Suite("AppLogger capture")
struct AppLoggerCaptureTests {
    // MARK: - Per-level capture

    @Test("trace produces one entry with level .trace and correct category")
    func captureTrace() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .audio, store: store)
        log.trace("trace.event")
        let entries = store.snapshot()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.level == .trace)
        #expect(entry.category == .audio)
    }

    @Test("debug produces one entry with level .debug and correct category")
    func captureDebug() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .playback, store: store)
        log.debug("decoder.start")
        let entries = store.snapshot()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.level == .debug)
        #expect(entry.category == .playback)
    }

    @Test("info produces one entry with level .info and correct category")
    func captureInfo() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .library, store: store)
        log.info("scan.complete")
        let entry = try #require(store.snapshot().first)
        #expect(entry.level == .info)
        #expect(entry.category == .library)
    }

    @Test("notice produces one entry with level .notice and correct category")
    func captureNotice() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .network, store: store)
        log.notice("connection.restored")
        let entry = try #require(store.snapshot().first)
        #expect(entry.level == .notice)
        #expect(entry.category == .network)
    }

    @Test("warning produces one entry with level .warning and correct category")
    func captureWarning() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .subsonic, store: store)
        log.warning("capabilities.stale")
        let entry = try #require(store.snapshot().first)
        #expect(entry.level == .warning)
        #expect(entry.category == .subsonic)
    }

    @Test("error produces one entry with level .error and correct category")
    func captureError() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .persistence, store: store)
        log.error("db.write.failed")
        let entry = try #require(store.snapshot().first)
        #expect(entry.level == .error)
        #expect(entry.category == .persistence)
    }

    @Test("fault produces one entry with level .fault and correct category")
    func captureFault() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .app, store: store)
        log.fault("invariant.violated")
        let entry = try #require(store.snapshot().first)
        #expect(entry.level == .fault)
        #expect(entry.category == .app)
    }

    // MARK: - Message equality

    @Test("stored message equals the string produced by format (no fields)")
    func messageEqualsFormatNoFields() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .audio, store: store)
        log.debug("decoder.start")
        let entry = try #require(store.snapshot().first)
        #expect(entry.message == "decoder.start")
    }

    @Test("stored message equals the string produced by format (with fields)")
    func messageEqualsFormatWithFields() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .audio, store: store)
        log.debug("decoder.start", ["format": "FLAC", "sampleRate": 44100])
        let entry = try #require(store.snapshot().first)
        // format() produces stable key-sorted suffix
        #expect(entry.message == "decoder.start [format=FLAC sampleRate=44100]")
    }

    // MARK: - Redaction in captured entries

    @Test("apiKey value is redacted in the captured message")
    func redactsApiKey() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .network, store: store)
        log.debug("auth.request", ["apiKey": "super-secret-key", "endpoint": "/search"])
        let entry = try #require(store.snapshot().first)
        #expect(
            entry.message.contains("apiKey=<redacted>"),
            "apiKey value must be redacted in captured entry"
        )
        #expect(
            !entry.message.contains("super-secret-key"),
            "Raw apiKey value must never appear in captured entry"
        )
        #expect(
            entry.message.contains("endpoint=/search"),
            "Non-sensitive field must be preserved"
        )
    }

    @Test("token value is redacted in the captured message")
    func redactsToken() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .scrobble, store: store)
        log.info("session.start", ["token": "tok_abc123", "user": "alice"])
        let entry = try #require(store.snapshot().first)
        #expect(entry.message.contains("token=<redacted>"))
        #expect(!entry.message.contains("tok_abc123"))
    }

    @Test("password value is redacted in the captured message")
    func redactsPassword() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .app, store: store)
        log.warning("auth.retry", ["password": "hunter2", "attempts": 3])
        let entry = try #require(store.snapshot().first)
        #expect(entry.message.contains("password=<redacted>"))
        #expect(!entry.message.contains("hunter2"))
    }

    @Test("all known sensitive keys are redacted in the captured message")
    func allSensitiveKeysRedacted() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .network, store: store)
        let sensitiveFields: [String: Any] = [
            "apiKey": "v1",
            "token": "v2",
            "sessionKey": "v3",
            "password": "v4",
            "authorization": "v5",
            "secret": "v6",
            "refreshToken": "v7",
            "accessToken": "v8",
        ]
        log.debug("sensitive.bundle", sensitiveFields)
        let entry = try #require(store.snapshot().first)
        for key in sensitiveFields.keys {
            #expect(
                entry.message.contains("\(key)=<redacted>") || entry.message.contains("\(key.lowercased())=<redacted>"),
                "\(key) must be redacted in captured entry"
            )
        }
        for value in ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8"] {
            #expect(
                !entry.message.contains(value),
                "Raw sensitive value \(value) must not appear in captured entry"
            )
        }
    }

    // MARK: - Capture toggle

    @Test("disabling capture makes record a no-op for AppLogger calls")
    func captureDisabledStopsEntries() {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .audio, store: store)
        store.isCaptureEnabled = false
        log.debug("should.not.appear")
        log.error("also.suppressed")
        #expect(store.snapshot().isEmpty)
    }

    @Test("re-enabling capture resumes storing entries from AppLogger")
    func captureReenabledResumesEntries() throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .audio, store: store)
        store.isCaptureEnabled = false
        log.debug("missed")
        store.isCaptureEnabled = true
        log.debug("captured")
        let entries = store.snapshot()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.message == "captured")
    }

    @Test("capture toggle does not affect os.Logger output (smoke)")
    func captureToggleDoesNotCrashOsLogger() {
        // We cannot observe os.Logger output in-process, but confirming the
        // logger methods do not crash when capture is off satisfies the spec.
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .app, store: store)
        store.isCaptureEnabled = false
        // Must not throw or crash.
        log.trace("t")
        log.debug("d")
        log.info("i")
        log.notice("n")
        log.warning("w")
        log.error("e")
        log.fault("f")
    }

    // MARK: - All seven levels in one store

    @Test("all seven levels each add one entry with the right level value")
    func allSevenLevelsCaptured() {
        let store = LogStore(capacity: 20)
        let log = AppLogger(category: .app, store: store)
        log.trace("t")
        log.debug("d")
        log.info("i")
        log.notice("n")
        log.warning("w")
        log.error("e")
        log.fault("f")

        let entries = store.snapshot()
        #expect(entries.count == 7)
        let levels = entries.map(\.level)
        #expect(levels == [.trace, .debug, .info, .notice, .warning, .error, .fault])
    }
}

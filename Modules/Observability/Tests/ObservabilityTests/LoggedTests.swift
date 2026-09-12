import Testing
@testable import Observability

/// #459: `logged` is the sanctioned recover-and-log shape from the `try?`
/// audit. The whole point of that audit is that the reason a fallback was
/// needed must survive, so what these pin is that the error reaches the log
/// and the caller still gets its nil back.
@Suite("logged recover-and-log helper")
struct LoggedTests {
    private struct Boom: Error {}

    @Test("a body that succeeds returns its value and logs nothing")
    func successLogsNothing() async {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .library, store: store)
        let value = await logged("read.failed", log) { 42 }
        #expect(value == 42)
        #expect(store.snapshot().isEmpty)
    }

    @Test("a body that throws returns nil and logs one warning naming the error")
    func failureLogsWarning() async throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .library, store: store)
        let value: Int? = await logged("read.failed", log) { throw Boom() }
        #expect(value == nil)
        let entries = store.snapshot()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.level == .warning)
        #expect(entry.category == .library)
        #expect(entry.message.contains("read.failed"))
        #expect(entry.message.contains("Boom"))
    }

    /// The context keys are the difference between a log line someone can act
    /// on and one that only says something went wrong somewhere.
    @Test("context keys reach the log line alongside the error")
    func contextIsCarried() async throws {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .sync, store: store)
        let value: Int? = await logged("read.failed", log, context: ["id": 7]) { throw Boom() }
        #expect(value == nil)
        let entry = try #require(store.snapshot().first)
        #expect(entry.message.contains("id"))
        #expect(entry.message.contains("7"))
    }

    /// A nil-returning body is the common case for a repository read, and the
    /// helper must not confuse "read succeeded, found nothing" with "failed".
    @Test("a body that returns nil is a success, not a failure")
    func nilResultIsNotAFailure() async {
        let store = LogStore(capacity: 10)
        let log = AppLogger(category: .library, store: store)
        let value: Int?? = await logged("read.failed", log) { Int?.none }
        #expect(value != nil)
        #expect(store.snapshot().isEmpty)
    }
}

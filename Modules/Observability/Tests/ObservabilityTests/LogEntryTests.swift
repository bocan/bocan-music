import Foundation
import Testing
@testable import Observability

@Suite("LogEntry")
struct LogEntryTests {
    private func makeEntry(
        id: UInt64 = 1,
        timestamp: Date = Date(timeIntervalSinceReferenceDate: 0),
        level: LogLevel = .debug,
        category: LogCategory = .audio,
        message: String = "decoder.start"
    ) -> LogEntry {
        LogEntry(id: id, timestamp: timestamp, level: level, category: category, message: message)
    }

    @Test("stores all fields verbatim")
    func storesFields() {
        let ts = Date(timeIntervalSinceReferenceDate: 1000)
        let entry = self.makeEntry(id: 42, timestamp: ts, level: .warning, category: .playback, message: "test.msg")
        #expect(entry.id == 42)
        #expect(entry.timestamp == ts)
        #expect(entry.level == .warning)
        #expect(entry.category == .playback)
        #expect(entry.message == "test.msg")
    }

    @Test("two entries with the same id and fields are equal")
    func equality() {
        let ts = Date(timeIntervalSinceReferenceDate: 500)
        let a = self.makeEntry(id: 7, timestamp: ts)
        let b = self.makeEntry(id: 7, timestamp: ts)
        #expect(a == b)
    }

    @Test("entries with different ids are not equal")
    func inequalityById() {
        let ts = Date(timeIntervalSinceReferenceDate: 500)
        let a = self.makeEntry(id: 1, timestamp: ts)
        let b = self.makeEntry(id: 2, timestamp: ts)
        #expect(a != b)
    }

    @Test("entries with different messages are not equal")
    func inequalityByMessage() {
        let a = self.makeEntry(message: "alpha")
        let b = self.makeEntry(message: "beta")
        #expect(a != b)
    }

    @Test("Identifiable id is the UInt64 sequence number")
    func identifiableId() {
        let entry = self.makeEntry(id: 999)
        // Accessing .id via the Identifiable conformance resolves to the same field.
        let _: UInt64 = entry.id
        #expect(entry.id == 999)
    }

    @Test("entry is usable as a Set element (Hashable)")
    func hashable() {
        let ts = Date(timeIntervalSinceReferenceDate: 0)
        let a = self.makeEntry(id: 1, timestamp: ts)
        let b = self.makeEntry(id: 2, timestamp: ts)
        let set: Set<LogEntry> = [a, b, a]
        #expect(set.count == 2)
    }
}

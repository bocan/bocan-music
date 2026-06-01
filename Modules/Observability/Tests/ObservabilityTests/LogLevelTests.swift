import Testing
@testable import Observability

@Suite("LogLevel")
struct LogLevelTests {
    @Test("cases are ordered low to high")
    func ordering() {
        #expect(LogLevel.trace < .debug)
        #expect(LogLevel.debug < .info)
        #expect(LogLevel.info < .notice)
        #expect(LogLevel.notice < .warning)
        #expect(LogLevel.warning < .error)
        #expect(LogLevel.error < .fault)
        #expect(LogLevel.debug < .warning)
        #expect(!(LogLevel.warning < .debug))
        #expect(!(LogLevel.info < .info))
    }

    @Test("rawValues are contiguous starting from zero")
    func rawValues() {
        #expect(LogLevel.trace.rawValue == 0)
        #expect(LogLevel.debug.rawValue == 1)
        #expect(LogLevel.info.rawValue == 2)
        #expect(LogLevel.notice.rawValue == 3)
        #expect(LogLevel.warning.rawValue == 4)
        #expect(LogLevel.error.rawValue == 5)
        #expect(LogLevel.fault.rawValue == 6)
    }

    @Test("label returns upper-case string for each case")
    func labels() {
        #expect(LogLevel.trace.label == "TRACE")
        #expect(LogLevel.debug.label == "DEBUG")
        #expect(LogLevel.info.label == "INFO")
        #expect(LogLevel.notice.label == "NOTICE")
        #expect(LogLevel.warning.label == "WARNING")
        #expect(LogLevel.error.label == "ERROR")
        #expect(LogLevel.fault.label == "FAULT")
    }

    @Test("allCases covers all seven levels")
    func allCases() {
        #expect(LogLevel.allCases.count == 7)
    }

    @Test("Comparable minimum and maximum via min/max")
    func minMax() {
        let levels: [LogLevel] = [.fault, .trace, .warning, .debug]
        #expect(levels.min() == .trace)
        #expect(levels.max() == .fault)
    }
}

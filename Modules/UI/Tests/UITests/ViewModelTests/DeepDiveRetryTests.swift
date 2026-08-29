import Combine
import Foundation
import Library
import Testing
@testable import UI

@Suite("Deep Dive retry (#413)")
@MainActor
struct DeepDiveRetryTests {
    private let fast: [Duration] = [.milliseconds(1), .milliseconds(1), .milliseconds(1)]

    @Test("a rate-limited attempt is retried once per delay, reporting the attempt number")
    func retriesThenSucceeds() async throws {
        var calls = 0
        var reported: [Int] = []
        let value = try await DeepDiveRetry.run(delays: self.fast, onRetry: { reported.append($0) }, attempt: {
            calls += 1
            if calls < 3 { throw DeepDiveError.rateLimited }
            return "ok"
        })
        #expect(value == "ok")
        #expect(calls == 3)
        #expect(reported == [1, 2])
    }

    @Test("after the last delay the rate-limit error propagates; other errors never retry")
    func exhaustsThenFails() async {
        var calls = 0
        await #expect(throws: DeepDiveError.rateLimited) {
            try await DeepDiveRetry.run(delays: self.fast, onRetry: { _ in }, attempt: {
                calls += 1
                throw DeepDiveError.rateLimited
            })
        }
        #expect(calls == 4, "one attempt plus one per delay")

        calls = 0
        await #expect(throws: DeepDiveError.offline) {
            try await DeepDiveRetry.run(delays: self.fast, onRetry: { _ in }, attempt: {
                calls += 1
                throw DeepDiveError.offline
            })
        }
        #expect(calls == 1)
    }

    @Test("the view model walks loading, retrying, loaded")
    func viewModelStates() async throws {
        let counter = Counter()
        let vm = DeepDiveReportViewModel<Int>(category: "test", delays: self.fast) { _ in
            if await counter.next() < 2 { throw DeepDiveError.rateLimited }
            return 42
        }
        let seen = Seen()
        let sink = vm.$state.dropFirst().sink { state in seen.states.append(state) }
        vm.load()
        for _ in 0 ..< 400 {
            if case .loaded = vm.state { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        sink.cancel()
        #expect(seen.states == [.loading, .retrying(attempt: 1, of: 3), .retrying(attempt: 2, of: 3), .loaded(42)])
    }

    @Test("the view model reports the rate limit only once the retries are spent")
    func viewModelGivesUp() async throws {
        let vm = DeepDiveReportViewModel<Int>(category: "test", delays: self.fast) { _ in throw DeepDiveError.rateLimited }
        vm.load()
        for _ in 0 ..< 200 {
            if case .failed = vm.state { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(vm.state == .failed(.rateLimited))
    }
}

@MainActor
private final class Seen {
    var states: [DeepDiveState<Int>] = []
}

private actor Counter {
    private var value = 0

    func next() -> Int {
        defer { self.value += 1 }
        return self.value
    }
}

import Foundation
import Testing

// MARK: - QuitWorkTests

/// `QuitWork` replaces the quit observers that blocked the main thread on a
/// semaphore (a priority inversion on every quit). AppKit is told
/// `.terminateLater` and must then get exactly one reply, so these pin the
/// reply: it comes once, after the jobs or at the limit, whichever is first,
/// and the jobs run side by side so one slow job does not eat the others'
/// time.
@Suite("Quit work")
@MainActor
struct QuitWorkTests {
    /// Counts calls to `done` and lets the test await the first one.
    @MainActor
    private final class Replies {
        var count = 0
        private var waiter: CheckedContinuation<Void, Never>?

        func record() {
            self.count += 1
            if self.count == 1 {
                self.waiter?.resume()
                self.waiter = nil
            }
        }

        func first() async {
            if self.count >= 1 {
                return
            }
            await withCheckedContinuation { self.waiter = $0 }
        }
    }

    /// An actor the jobs report to, so a test can see what ran.
    private actor Log {
        private(set) var finished = 0
        private(set) var started = 0

        func start() {
            self.started += 1
        }

        func finish() {
            self.finished += 1
        }
    }

    /// Holds a job until the test opens it, so "hung" does not depend on a
    /// sleep racing the limit on a loaded CI machine.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if self.isOpen {
                return
            }
            await withCheckedContinuation { self.waiters.append($0) }
        }

        func open() {
            self.isOpen = true
            for waiter in self.waiters {
                waiter.resume()
            }
            self.waiters = []
        }
    }

    @Test("With no jobs the reply still comes")
    func emptyReplies() async {
        let work = QuitWork()
        let replies = Replies()
        #expect(work.isEmpty)
        work.run(limit: .seconds(30)) { replies.record() }
        await replies.first()
        #expect(replies.count == 1)
    }

    @Test("The reply waits for every job to finish")
    func repliesAfterJobs() async {
        let work = QuitWork()
        let log = Log()
        let replies = Replies()
        for _ in 0 ..< 3 {
            work.add {
                await Task.yield()
                await log.finish()
            }
        }
        #expect(!work.isEmpty)
        work.run(limit: .seconds(30)) { replies.record() }
        await replies.first()
        #expect(await log.finished == 3)
        #expect(replies.count == 1)
    }

    /// Each job waits until both have started. Run one after the other, the
    /// first would never finish and only the 30 s limit would end it.
    @Test("The jobs run side by side")
    func jobsRunInParallel() async {
        let work = QuitWork()
        let log = Log()
        let replies = Replies()
        for _ in 0 ..< 2 {
            work.add {
                await log.start()
                while await log.started < 2 {
                    await Task.yield()
                }
                await log.finish()
            }
        }
        work.run(limit: .seconds(30)) { replies.record() }
        await replies.first()
        #expect(await log.finished == 2)
    }

    /// A job that hangs past the limit must not hold the quit, and when it
    /// does finish later it must not send AppKit a second reply.
    @Test("A hung job is cut off at the limit, with one reply only")
    func limitCutsOffAHungJob() async throws {
        let work = QuitWork()
        let log = Log()
        let replies = Replies()
        let gate = Gate()
        work.add {
            await gate.wait()
            await log.finish()
        }
        work.run(limit: .milliseconds(20)) { replies.record() }
        await replies.first()
        #expect(await log.finished == 0, "the reply came before the hung job ended")

        // Let the job end, and its late completion try to reply again.
        await gate.open()
        while await log.finished == 0 {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(replies.count == 1)
    }
}

import Foundation

// MARK: - QuitWork

/// Async work that must finish before the process exits: saving the playback
/// position, the database vacuum, withdrawing Phone Sync.
///
/// `AppDelegate.applicationShouldTerminate` runs it and answers AppKit with
/// `.terminateLater`, then replies once the jobs are done. It used to run
/// from `willTerminate` observers that blocked the main thread on a
/// semaphore while a detached task did the work. The main thread runs at
/// user-interactive QoS and the task ran at default, so every quit was a
/// priority inversion, and Xcode's Thread Performance Checker reported it on
/// each debug quit. Now the main thread never waits: the jobs run in
/// parallel off it, and the reply comes back on it.
///
/// Compiled into the test bundle as well (`project.yml`), so it imports only
/// Foundation.
@MainActor
final class QuitWork {
    /// The longest a quit waits for the jobs. A job still running then is
    /// abandoned with the process, as the old semaphore timeouts did.
    nonisolated static let limit: Duration = .seconds(2)

    private var jobs: [@Sendable () async -> Void] = []

    var isEmpty: Bool {
        self.jobs.isEmpty
    }

    func add(_ job: @escaping @Sendable () async -> Void) {
        self.jobs.append(job)
    }

    /// Runs every job in parallel and calls `done` exactly once, on the main
    /// actor: when the last job finishes, or when `limit` passes, whichever
    /// comes first.
    func run(limit: Duration = QuitWork.limit, done: @escaping @MainActor () -> Void) {
        let once = RunOnce(done)
        let jobs = self.jobs
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for job in jobs {
                    group.addTask { await job() }
                }
            }
            await once.fire()
        }
        Task { @MainActor in
            do {
                try await Task.sleep(for: limit)
            } catch {
                // Only cancellation throws here, and nothing cancels this task.
                return
            }
            once.fire()
        }
    }
}

// MARK: - RunOnce

/// Holds a main-actor action and runs it the first time `fire()` is called;
/// later calls do nothing. The jobs finishing and the time limit both fire
/// it, and AppKit must get exactly one reply.
@MainActor
private final class RunOnce {
    private var action: (@MainActor () -> Void)?

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func fire() {
        let action = self.action
        self.action = nil
        action?()
    }
}

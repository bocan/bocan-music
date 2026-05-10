import AppKit
import Foundation
import Observability

// MARK: - SingleInstance

/// Enforces that only one Bòcan process runs at a time.
///
/// **Mechanism — belt-and-suspenders:**
///
/// 1. **Exclusive file lock** (`flock F_SETLK`) on
///    `~/Library/Application Support/Bocan/bocan.lock`.
///    If the lock cannot be acquired another instance already owns it — we
///    activate that instance and `exit(0)` before any subsystem is initialised.
///
/// 2. **DistributedNotificationCenter** — the first instance registers an
///    observer for `activationNotification`. Subsequent launches post that
///    notification (handled by the first instance) and then exit via the lock
///    check above, so there is no timing race between the two mechanisms.
///
/// Call `start()` as the **very first thing** in `BocanApp.init()`, before any
/// subsystem initialisation.  Call `stop()` from
/// `AppDelegate.applicationWillTerminate(_:)` to release the lock and remove the
/// observer.
@MainActor
final class SingleInstance {
    // MARK: Constants

    /// Notification name broadcast by a second-instance candidate.
    /// Also used as the unit-test anchor — see `SingleInstanceTests`.
    nonisolated static let activationNotification = "io.cloudcauldron.bocan.activate"

    // MARK: Singleton

    static let shared = SingleInstance()

    // MARK: Private state

    private let log = AppLogger.make(.app)
    private var observer: NSObjectProtocol?
    /// File descriptor of the open lock file.  Kept open so the OS releases the
    /// advisory lock when this process terminates (even via `exit()`).
    private var lockFd: Int32 = -1

    // MARK: Init

    private init() {}

    // MARK: Public API

    /// Start single-instance enforcement.
    ///
    /// - If the lock can be acquired: register the activation observer and
    ///   return normally.
    /// - If the lock is held by another process: post the activation
    ///   notification to bring that process to the front, then `exit(0)`.
    func start() {
        // Step 1: Try to acquire the exclusive lock.
        let lockURL = Self.lockFileURL()
        if !self.acquireLock(at: lockURL) {
            // Another instance owns the lock — activate it and exit.
            self.log.info("single_instance.second_launch_detected", ["action": "activating_existing"])
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(Self.activationNotification),
                object: nil,
                deliverImmediately: true
            )
            // Give the notification a moment to reach the first instance before
            // we exit, so its window appears before this process's windows do.
            Thread.sleep(forTimeInterval: 0.25)
            exit(0)
        }

        // Step 2: We are the first instance. Register to handle future attempts.
        self.log.debug("single_instance.lock_acquired")
        self.observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(Self.activationNotification),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.bringToFront() }
        }
    }

    /// Stop single-instance enforcement (call from `applicationWillTerminate`).
    ///
    /// Removes the distributed-notification observer and closes the lock fd,
    /// releasing the advisory lock for the next launch.
    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
        if self.lockFd >= 0 {
            close(self.lockFd)
            self.lockFd = -1
        }
        self.log.debug("single_instance.lock_released")
    }

    // MARK: Private helpers

    /// Tries to take an exclusive, non-blocking `flock` on `url`.
    ///
    /// Returns `true` if the lock was acquired (we are the first instance).
    /// Returns `false` if another process already holds the lock.
    /// If the file cannot be opened (permissions issue, …) we conservatively
    /// return `true` so the app proceeds rather than refusing to launch.
    private func acquireLock(at url: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            self.log.warning("single_instance.lock_file_open_failed", ["path": url.path])
            return true // Can't open → proceed optimistically.
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        if fcntl(fd, F_SETLK, &lock) == 0 {
            self.lockFd = fd // Keep fd open; lock is released when fd is closed.
            return true
        }
        // Lock held by another PID.
        close(fd)
        return false
    }

    private func bringToFront() {
        self.log.info("single_instance.activate_requested")
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.mainWindow ?? NSApp.windows.first { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }

    private static func lockFileURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Bocan/bocan.lock")
    }
}

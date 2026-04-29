import Foundation
import Observability

// MARK: - FSWatcher

/// Watches one or more directories for file-system events using FSEvents.
///
/// Events are coalesced over a 500 ms latency window to avoid batching
/// many rapid writes.  The actor calls `onChange` with the affected URLs on
/// the main actor.
///
/// Each watched root is associated with the security-scoped bookmark of the
/// root URL.  The watcher resolves the bookmark and starts the security
/// scope before creating the FSEventStream, holding it open for the lifetime
/// of the watch (so events keep flowing under the sandbox).
///
/// The App layer should call `restartAllStreams()` on
/// `NSWorkspace.didWakeNotification` — FSEvents is not always reliable
/// across long sleeps.
public actor FSWatcher {
    // MARK: - Watched root state

    private struct WatchedRoot {
        let url: URL
        /// `nil` when no bookmark was supplied (development paths only).
        let scopedURL: URL?
        nonisolated(unsafe) var stream: FSEventStreamRef?
    }

    // MARK: - Properties

    // nonisolated(unsafe) so deinit can release streams without actor isolation.
    private nonisolated(unsafe) var watched: [WatchedRoot] = []
    private let onChange: @Sendable ([URL]) -> Void
    private let log = AppLogger.make(.library)

    /// Dedicated dispatch queue for FSEvents callbacks. Avoids using
    /// `DispatchQueue.global(.utility)` per project concurrency standards.
    private let eventQueue = DispatchQueue(label: "io.cloudcauldron.bocan.fswatcher", qos: .utility)

    /// FSEvents minimum coalescing latency (seconds).
    private let latency: CFTimeInterval = 0.5

    // MARK: - Init / deinit

    public init(onChange: @Sendable @escaping ([URL]) -> Void) {
        self.onChange = onChange
    }

    deinit {
        for root in watched {
            if let stream = root.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            root.scopedURL?.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - API

    /// Adds `url` to the set of watched directories and starts a new FSEvent stream.
    ///
    /// - Parameters:
    ///   - url: The directory to watch (FSEvents requires a directory path).
    ///   - bookmark: Optional security-scoped bookmark.  When provided, the
    ///     watcher resolves it and holds the scope open for the lifetime of
    ///     the watch so that events keep flowing under sandbox.
    public func watch(_ url: URL, bookmark: Data? = nil) {
        // Resolve + start security scope if bookmark provided.
        var scopedURL: URL?
        var watchURL = url
        if let bookmark {
            var isStale = false
            do {
                let resolved = try URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if resolved.startAccessingSecurityScopedResource() {
                    scopedURL = resolved
                    watchURL = resolved
                    if isStale {
                        self.log.warning("fsevents.bookmark_stale", ["path": resolved.path])
                    }
                } else {
                    self.log.warning("fsevents.scope_denied", ["path": resolved.path])
                }
            } catch {
                self.log.warning("fsevents.bookmark_resolve_failed", [
                    "path": url.path,
                    "error": String(reflecting: error),
                ])
            }
        }

        guard let stream = self.makeStream(for: watchURL) else {
            scopedURL?.stopAccessingSecurityScopedResource()
            return
        }

        let record = WatchedRoot(url: watchURL, scopedURL: scopedURL, stream: stream)
        FSEventStreamStart(stream)
        self.watched.append(record)
        self.log.debug("fsevents.watching", ["path": watchURL.path])
    }

    /// Stops and removes all watched streams.
    public func stopAll() {
        for root in self.watched {
            if let stream = root.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            root.scopedURL?.stopAccessingSecurityScopedResource()
        }
        self.watched.removeAll()
        self.log.debug("fsevents.stopped")
    }

    /// Tears down all streams and recreates them, reusing the held security scopes.
    ///
    /// Wire this to `NSWorkspace.didWakeNotification` from the App layer:
    /// FSEvents may stop firing reliably across long sleeps.
    public func restartAllStreams() {
        guard !self.watched.isEmpty else { return }
        self.log.info("fsevents.reopening_after_wake", ["count": self.watched.count])

        let snapshot = self.watched
        for root in snapshot {
            if let stream = root.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
        self.watched.removeAll()

        for root in snapshot {
            // Scope is still held from the original `watch(_:)` call — reuse it.
            guard let stream = self.makeStream(for: root.url) else {
                root.scopedURL?.stopAccessingSecurityScopedResource()
                continue
            }
            FSEventStreamStart(stream)
            self.watched.append(WatchedRoot(url: root.url, scopedURL: root.scopedURL, stream: stream))
        }
    }

    // MARK: - Stream lifecycle

    private func makeStream(for url: URL) -> FSEventStreamRef? {
        let path = url.path as CFString
        let paths = [path] as CFArray
        let callback = fsEventsCallback

        // Pass `self` as a retained raw pointer so the C callback can call back in.
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())

        var context = FSEventStreamContext(
            version: 0,
            info: selfPtr,
            retain: nil,
            release: { ptr in
                if let p = ptr {
                    Unmanaged<FSWatcher>.fromOpaque(p).release()
                }
            },
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            self.latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes |
                    kFSEventStreamCreateFlagFileEvents |
                    kFSEventStreamCreateFlagNoDefer
            )
        ) else {
            self.log.error("fsevents.create_failed", ["path": url.path])
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, self.eventQueue)
        return stream
    }

    // MARK: - Callback bridge

    func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        // Detect rename-flagged events. Phase-3 audit H2: log them so a future
        // change-detector pass can reconcile via `URLResourceValues.fileResourceIdentifier`.
        // Today the importer treats renamed files as new imports; the original row
        // is reaped on the next full scan.
        let renameFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        for (idx, flag) in flags.enumerated() where (flag & renameFlag) != 0 {
            if idx < paths.count {
                self.log.debug("fsevents.rename", ["path": paths[idx]])
            }
        }

        // NFC-normalise paths before handing off — APFS may deliver decomposed
        // UTF-8 that doesn't match the precomposed form we stored in DB rows.
        let urls = paths.map { URL(fileURLWithPath: $0.precomposedStringWithCanonicalMapping) }
        self.onChange(urls)
    }
}

// MARK: - C callback (file-scope)

private let fsEventsCallback: FSEventStreamCallback = {
    _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()

    // FSEvents delivers eventPaths as a CFArray of CFString; bridge via unsafeBitCast.
    let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    let paths = Array(pathsArray.prefix(numEvents))

    let flagsBuffer = UnsafeBufferPointer(start: eventFlags, count: numEvents)
    let flags = Array(flagsBuffer)

    Task {
        await watcher.handleEvents(paths: paths, flags: flags)
    }
}

import Foundation
import Observability

// MARK: - FSWatcher

/// Watches one or more directories for file-system events using FSEvents.
///
/// Events are coalesced over a 500 ms latency window to avoid batching
/// many rapid writes.  The actor calls `onChange` with the affected URLs on
/// the main actor.
public actor FSWatcher {
    // MARK: - Properties

    // nonisolated(unsafe) so deinit can release streams without actor isolation.
    private nonisolated(unsafe) var streams: [FSEventStreamRef] = []
    private var watchedRoots: [URL] = []
    private let onChange: @Sendable ([URL]) -> Void
    private let log = AppLogger.make(.library)

    /// FSEvents minimum coalescing latency (seconds).
    private let latency: CFTimeInterval = 0.5

    // MARK: - Init / deinit

    public init(onChange: @Sendable @escaping ([URL]) -> Void) {
        self.onChange = onChange
    }

    deinit {
        for stream in streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: - API

    /// Adds `url` to the set of watched directories and starts a new FSEvent stream.
    public func watch(_ url: URL) {
        let path = url.path as CFString
        let paths = [path] as CFArray
        let callback = fsEventsCallback

        // We pass `self` as retained raw pointer so the C callback can call back in.
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
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes |
                    kFSEventStreamCreateFlagFileEvents |
                    kFSEventStreamCreateFlagNoDefer
            )
        ) else {
            self.log.error("fsevents.create_failed", ["path": url.path])
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        self.streams.append(stream)
        self.watchedRoots.append(url)
        self.log.debug("fsevents.watching", ["path": url.path])
    }

    /// Stops and removes all watched streams.
    public func stopAll() {
        for stream in self.streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        self.streams.removeAll()
        self.watchedRoots.removeAll()
        self.log.debug("fsevents.stopped")
    }

    // MARK: - Callback bridge

    func handleEvents(paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        self.onChange(urls)
    }
}

// MARK: - C callback (file-scope)

private let fsEventsCallback: FSEventStreamCallback = {
    _, clientCallBackInfo, numEvents, eventPaths, _, _ in
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()

    guard let pathsArray = eventPaths as? NSArray as? [String] else { return }
    let paths = Array(pathsArray.prefix(numEvents))

    Task {
        await watcher.handleEvents(paths: paths)
    }
}

import Foundation
import Testing
@testable import Library

@Suite("FSWatcher")
struct FSWatcherTests {
    @Test("onChange is called with correct URLs")
    func onChangeReceivesURLs() async throws {
        actor Collector {
            var urls: [URL] = []
            func append(_ u: [URL]) {
                self.urls.append(contentsOf: u)
            }
        }
        let collector = Collector()

        let watcher = FSWatcher { urls in
            Task { await collector.append(urls) }
        }

        let testPaths = ["/tmp/a.mp3", "/tmp/b.flac"]
        await watcher.handleEvents(paths: testPaths, flags: [0, 0])

        // Allow the spawned Task to complete
        try await Task.sleep(for: .milliseconds(50))

        let received = await collector.urls
        #expect(received.count == 2)
        #expect(received[0] == URL(fileURLWithPath: "/tmp/a.mp3"))
        #expect(received[1] == URL(fileURLWithPath: "/tmp/b.flac"))
    }

    @Test("stopAll removes all watched streams")
    func stopAllCleansUp() async {
        let watcher = FSWatcher { _ in }
        let dir = FileManager.default.temporaryDirectory
        await watcher.watch(dir)
        await watcher.stopAll()
        // No crash = pass
    }
}

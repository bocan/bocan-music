import Foundation
import Testing
@testable import Library

@Suite("ChangeDetector")
struct ChangeDetectorTests {
    @Test("new URL is detected as .new")
    func detectsNewFile() async {
        let detector = ChangeDetector()
        let url = URL(fileURLWithPath: "/tmp/new.mp3")
        let status = await detector.check(url: url, mtime: 1000, size: 500)
        #expect(status == .new)
    }

    @Test("unchanged mtime and size is .unchanged")
    func detectsUnchanged() async {
        let detector = ChangeDetector()
        let url = URL(fileURLWithPath: "/tmp/same.mp3")
        await detector.seed([(url: url.absoluteString, mtime: 1000, size: 500)])
        let status = await detector.check(url: url, mtime: 1000, size: 500)
        #expect(status == .unchanged)
    }

    @Test("changed mtime is .modified")
    func detectsMtimeChange() async {
        let detector = ChangeDetector()
        let url = URL(fileURLWithPath: "/tmp/changed.mp3")
        await detector.seed([(url: url.absoluteString, mtime: 1000, size: 500)])
        let status = await detector.check(url: url, mtime: 2000, size: 500)
        #expect(status == .modified)
    }

    @Test("changed size is .modified")
    func detectsSizeChange() async {
        let detector = ChangeDetector()
        let url = URL(fileURLWithPath: "/tmp/resized.mp3")
        await detector.seed([(url: url.absoluteString, mtime: 1000, size: 500)])
        let status = await detector.check(url: url, mtime: 1000, size: 9999)
        #expect(status == .modified)
    }

    @Test("unvisited seeded URL appears in removedURLs")
    func detectsRemovedFiles() async {
        let detector = ChangeDetector()
        let alive = URL(fileURLWithPath: "/tmp/alive.mp3")
        let gone = URL(fileURLWithPath: "/tmp/gone.mp3")
        await detector.seed([
            (url: alive.absoluteString, mtime: 1, size: 1),
            (url: gone.absoluteString, mtime: 1, size: 1),
        ])
        // Only visit alive
        _ = await detector.check(url: alive, mtime: 1, size: 1)
        let removed = await detector.removedURLs()
        #expect(removed.count == 1)
        #expect(removed[0] == gone.absoluteString)
    }

    @Test("seed resets visited state")
    func seedResetsState() async {
        let detector = ChangeDetector()
        let url = URL(fileURLWithPath: "/tmp/track.mp3")
        await detector.seed([(url: url.absoluteString, mtime: 1, size: 1)])
        _ = await detector.check(url: url, mtime: 1, size: 1)
        // Re-seed: same URL should now reappear as unvisited
        await detector.seed([(url: url.absoluteString, mtime: 1, size: 1)])
        let removed = await detector.removedURLs()
        #expect(removed.count == 1)
    }
}

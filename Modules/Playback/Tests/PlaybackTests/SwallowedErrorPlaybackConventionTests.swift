import Foundation
import Testing
@testable import Playback

// MARK: - SwallowedErrorPlaybackConventionTests

/// #494: thirteen recoveries in this module were correct but silent
/// (`docs/audits/try-optional-audit.md`, class (b)). The recoveries are
/// unchanged, so what needs pinning is the log line that explains each one,
/// and a log cannot be read back from a test.
@Suite("Swallowed-error conventions in Playback (#494)")
struct SwallowedErrorPlaybackConventionTests {
    private var sourceRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // PlaybackTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/Playback/
            .appendingPathComponent("Sources/Playback")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("the player logs the reads and writes it recovers from")
    func queuePlayerRecoveriesAreLogged() throws {
        let source = try self.source("QueuePlayer.swift")
        let events = [
            "queueplayer.nowPlaying.trackLookupFailed",
            "queueplayer.markers.readFailed",
            "queueplayer.skip.disableFailed",
            "queueplayer.gapless.albumLookupFailed",
            "queueplayer.availability.rootsUnavailable",
            "queueplayer.availability.bookmarkUnresolvable",
            "queueplayer.root.rootsUnavailable",
            "queueplayer.root.bookmark_refresh_mintFailed",
            "queueplayer.buildItems.artistsUnavailable",
        ]
        for event in events {
            #expect(source.contains(event), "missing \(event)")
        }
        #expect(!source.contains("try? await trackRepo.fetch("))
        #expect(!source.contains("try? self.rootRepo.fetchAll()"))
    }

    @Test("the queue's legacy-blob removals say when they failed")
    func queuePersistenceRemovalsAreLogged() throws {
        let source = try self.source("Persistence/QueuePersistence.swift")
        #expect(source.contains("queue.restore.futureBlobRemoveFailed"))
        #expect(source.contains("queue.restore.legacyBlobRemoveFailed"))
        #expect(!source.contains("try? await self.repo.remove("))
    }

    /// The module's whole allowlist is one idiom, so it can be asserted
    /// outright: anything else swallowing an error is a regression.
    @Test("every remaining try? in this module is a cancellation-only sleep")
    func onlySleepsSwallow() throws {
        let enumerator = try #require(
            FileManager.default.enumerator(at: self.sourceRoot, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("try?"), !trimmed.hasPrefix("//") else { continue }
                if !trimmed.contains("Task.sleep") {
                    offenders.append("\(url.lastPathComponent): \(trimmed)")
                }
            }
        }
        #expect(offenders.isEmpty, "a swallowed error outside the allowlist: \(offenders)")
    }
}

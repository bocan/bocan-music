import Foundation
import Testing
@testable import Podcasts

// MARK: - SwallowedErrorPodcastsConventionTests

/// #495: the audit found ten reads in this module that recovered correctly and
/// then said nothing (`docs/audits/try-optional-audit.md`, class (b)). Every
/// recovery and every fallback value is unchanged. What needed pinning is the
/// log line that now explains each one, and a log cannot be read back from a
/// test.
@Suite("Swallowed-error conventions in Podcasts (#495)")
struct SwallowedErrorPodcastsConventionTests {
    private var sourceRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // PodcastsTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/Podcasts/
            .appendingPathComponent("Sources/Podcasts")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("auto-download says when it re-downloads because a state read failed")
    func autoDownloadLogsStateReadFailure() throws {
        let source = try self.source("Downloads/AutoDownloadCoordinator.swift")
        #expect(source.contains("autoDownload.stateReadFailed"))
        #expect(!source.contains("try?"), "a state read here silently forces a re-download")
    }

    /// The state read decides whether an episode is fetched again, and the row
    /// query decides whether anything is evicted. Both recover to "nothing
    /// found", which is the same answer a healthy empty library gives.
    @Test("the download manager logs every state read it recovers from")
    func downloadManagerLogsRecoveredReads() throws {
        let source = try self.source("Downloads/EpisodeDownloadManager.swift")
        let events = [
            "download.stateReadFailed",
            "download.stateQueryFailed",
            "download.enqueue.episodeReadFailed",
        ]
        for event in events {
            #expect(source.contains(event), "missing \(event)")
        }
        #expect(!source.contains("try?"), "a swallowed read still decides a download")
    }

    /// A database fault and an episode that is genuinely absent are different
    /// facts. Before #495 both arrived as `unknownEpisode`.
    @Test("an unreadable episode row is not reported as an unknown episode")
    func readFailureIsNotReportedAsUnknown() throws {
        let source = try self.source("Downloads/EpisodeDownloadManager.swift")
        #expect(source.contains("download.enqueue.unknownEpisode"))
        #expect(source.contains("download.enqueue.episodeReadFailed"))
    }

    @Test("the service says when retention and episode art were skipped")
    func serviceLogsSkippedWork() throws {
        let source = try self.source("PodcastService.swift")
        #expect(source.contains("podcast.retentionRead.failed"))
        #expect(source.contains("podcast.episodeArt.lookupFailed"))
    }

    /// This module's allowlist is not a single idiom, so it is spelled out.
    /// Anything else swallowing an error is a regression.
    @Test("every remaining try? in this module is an allowlisted idiom")
    func onlyAllowlistedIdiomsSwallow() throws {
        let allowed = [
            "JSONDecoder", "JSONEncoder",
            "FileHandle(forReadingFrom:",
            "handle.close()",
            "resourceValues(forKeys:",
            "Feed(data:",
            "(try? self.podcastRepo.fetch(id: podcastID)).flatMap",
        ]
        let enumerator = try #require(
            FileManager.default.enumerator(at: self.sourceRoot, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("try?"), !trimmed.hasPrefix("//") else { continue }
                if !allowed.contains(where: trimmed.contains) {
                    offenders.append("\(url.lastPathComponent): \(trimmed)")
                }
            }
        }
        #expect(offenders.isEmpty, "a swallowed error outside the allowlist: \(offenders)")
    }
}

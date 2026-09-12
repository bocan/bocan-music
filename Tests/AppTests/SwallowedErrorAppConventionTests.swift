import Foundation
import Testing

// MARK: - SwallowedErrorAppConventionTests

/// #459: the `try?` audit found App-layer sites that swallowed an error the
/// user or the log needed (`docs/audits/try-optional-audit.md`, class (c)).
/// The composition root cannot run host-less, so these pin the fixed shapes
/// in the source: the error is caught and logged with context, not dropped.
@Suite("Swallowed-error conventions in App/ (#459)")
struct SwallowedErrorAppConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the Subsonic stream cache init failure is logged with its directory, not swallowed (#483)")
    func streamCacheInitIsLogged() throws {
        let app = try self.source("App/BocanApp.swift")
        #expect(!app.contains("try? SubsonicStreamCache("), "a failed init left Subsonic unplayable with no log line")
        #expect(app.contains("subsonicStreamCache = try SubsonicStreamCache("))
        #expect(app.contains("log.error(\"subsonic.streamCache.init_failed\""))
        #expect(app.contains("\"dir\": streamCacheDir.path"))
    }
}

// MARK: - QuietRecoveryAppConventionTests

/// #493: the audit found fourteen reads in the App layer that recovered
/// correctly and then said nothing (`docs/audits/try-optional-audit.md`, class
/// (b)). Every recovery and every fallback value is unchanged. What needed
/// pinning is the log line that now explains each one. The composition root
/// cannot run host-less, and a log cannot be read back from a test.
@Suite("Quiet-recovery conventions in App/ (#493)")
struct QuietRecoveryAppConventionTests {
    private var appRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every one of these recovered to "nothing found", which is the same
    /// answer a healthy but empty install gives.
    @Test("the launch fan-out says which step it recovered from")
    func launchFanOutLogsRecoveries() throws {
        let source = try self.source("BocanApp.swift")
        let events = [
            "playback.resumeOnWake.failed",
            "subsonic.bootstrap.reloadClientsFailed",
            "subsonic.launch.migrateOrphansFailed",
            "subsonic.launch.reloadClientsFailed",
            "subsonic.launch.serversReadFailed",
            "subsonic.launch.capabilitiesFailed",
            "subsonic.launch.pruneStaleCacheFailed",
            "backup.settingRead.failed",
        ]
        for event in events {
            #expect(source.contains(event), "missing \(event)")
        }
    }

    /// A failed read and an unset key both fell back to the default. Local
    /// backups default to on, so a failed read could start writing backups the
    /// user had switched off.
    @Test("a backup setting that cannot be read is not silently defaulted")
    func backupSettingsReportReadFailures() throws {
        let source = try self.source("BocanApp.swift")
        #expect(!source.contains("try? settings.get("), "a failed read still passes for an unset key")
        #expect(source.contains("private static func setting<T: Codable & Sendable>"))
    }

    @Test("these files no longer swallow a read they recover from")
    func recoveringFilesSayWhy() throws {
        let cases = [
            ("PhoneSyncController.swift", "sync.playlists.readFailed"),
            ("PhoneSyncController.swift", "sync.pairedDevices.readFailed"),
            ("SubsonicStoreSidebarListing.swift", "subsonic.capabilitiesCache.decodeFailed"),
            ("SubsonicStreamResolver.swift", "subsonic.precache.serverReadFailed"),
        ]
        for (path, event) in cases {
            let source = try self.source(path)
            #expect(source.contains(event), "missing \(event)")
            #expect(!source.contains("try?"), "\(path) still swallows a read error")
        }
    }

    /// A comment-only `catch` is the same defect as a `try?` and no search for
    /// `try?` can see it. Keeping the conformance non-throwing is right;
    /// dropping the error is not, because the player's own log line cannot name
    /// the episode the person pressed play on.
    @Test("a catch that only carried a comment now names the episode")
    func podcastPlayFailureIsLogged() throws {
        let source = try self.source("AppPodcastActions.swift")
        #expect(source.contains("podcast.play.failed"))
        #expect(source.contains("\"guid\": episode.episode.guid"))
    }

    /// The App layer's allowlist is not a single idiom, so it is spelled out.
    /// `DebugAudioView` is skipped whole: the audit classes it as debug
    /// tooling, not shipping behaviour.
    @Test("every remaining try? in the App layer is an allowlisted idiom")
    func onlyAllowlistedIdiomsSwallow() throws {
        let allowed = [
            "FileManager.default.url(",
            "createDirectory",
            "removeItem",
            "database.vacuum()",
        ]
        let skippedFiles = ["DebugAudioView.swift"]
        let enumerator = try #require(
            FileManager.default.enumerator(at: self.appRoot, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard !skippedFiles.contains(url.lastPathComponent) else { continue }
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

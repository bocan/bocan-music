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

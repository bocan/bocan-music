import Foundation
import Testing

// MARK: - JellyfinPlaybackWiringTests

/// ADR-097 slice 5: the composition root cannot run host-less, so these pin the
/// Jellyfin playback wiring in the source.
@Suite("Jellyfin playback wiring (ADR-097)")
struct JellyfinPlaybackWiringTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the player gets a Jellyfin resolver built from its own stream cache folder")
    func playerGetsTheResolver() throws {
        let app = try self.source("App/BocanApp.swift")
        #expect(app.contains("jellyfin.makeStreamResolver(cachesFolder:"))
        #expect(app.contains("jellyfinResolver: jellyfinStreamResolver"))

        let wiring = try self.source("App/JellyfinWiring.swift")
        #expect(wiring.contains("\"JellyfinStreams\""), "Jellyfin streams need their own folder, apart from SubsonicStreams")
        #expect(wiring.contains("log.error(\"jellyfin.streamCache.initFailed\""))
    }

    @Test("removing a server clears that server's stream cache folder")
    func removalPurgesTheCache() throws {
        let wiring = try self.source("App/JellyfinWiring.swift")
        #expect(wiring.contains("setServerRemovedHandler"))
        #expect(wiring.contains("try await cache.purge(serverID: serverID)"))
        #expect(wiring.contains("jellyfin.streamCache.purgeFailed"))
    }

    @Test("the resolver never logs the stream URL, which carries the token")
    func resolverKeepsTheURLOutOfTheLog() throws {
        let resolver = try self.source("App/JellyfinStreamResolver.swift")
        #expect(resolver.contains("service.streamURL("))
        let logLines = resolver.split(separator: "\n").filter { $0.contains("log.") }
        #expect(!logLines.isEmpty)
        for line in logLines {
            #expect(!line.lowercased().contains("url"), "a log line mentions a URL: \(line)")
        }
    }
}

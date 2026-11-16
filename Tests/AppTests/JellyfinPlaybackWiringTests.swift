import Foundation
import Testing

// MARK: - JellyfinPlaybackWiringTests

/// ADR-097 slices 5 and 6: the composition root cannot run host-less, so these
/// pin the Jellyfin playback, play-report and favourites wiring in the source.
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
        #expect(app.contains("jellyfin.makeStreamResolver("))
        #expect(app.contains("jellyfinResolver: jellyfinStreamResolver"))
        // Slice 9: an E2E run streams into its own home, never the real Caches.
        #expect(app.contains("cachesFolder: E2EEnvironment.jellyfinCachesFolder ??"))

        let wiring = try self.source("App/JellyfinWiring.swift")
        #expect(wiring.contains("\"JellyfinStreams\""), "Jellyfin streams need their own folder, apart from SubsonicStreams")
        #expect(wiring.contains("log.error(\"jellyfin.streamCache.initFailed\""))
    }

    @Test("an E2E run keeps its Jellyfin token under its own Keychain service (ADR-097 slice 9)")
    func e2eKeepsItsOwnKeychainService() throws {
        let wiring = try self.source("App/JellyfinWiring.swift")
        #expect(wiring.contains("if let service = E2EEnvironment.jellyfinKeychainService"))
        let environment = try self.source("App/E2EEnvironment.swift")
        #expect(environment.contains("self.isActive ? \"io.cloudcauldron.bocan.jellyfin.e2e\" : nil"))
    }

    @Test("removing a server clears that server's stream cache folder")
    func removalPurgesTheCache() throws {
        let wiring = try self.source("App/JellyfinWiring.swift")
        #expect(wiring.contains("setServerRemovedHandler"))
        #expect(wiring.contains("try await cache.purge(serverID: serverID)"))
        #expect(wiring.contains("jellyfin.streamCache.purgeFailed"))
    }

    @Test("Jellyfin play reports are a scrobble provider, and a refused token makes the monitor check again")
    func playReportsAreWired() throws {
        let app = try self.source("App/BocanApp.swift")
        #expect(app.contains("providers.append(JellyfinScrobbleProvider(delivery: jellyfinDelivery))"))
        #expect(app.contains("jellyfinDelivery: jellyfin.scrobbleDelivery"))

        let delivery = try self.source("App/JellyfinScrobbleDelivery.swift")
        #expect(delivery.contains("await self.monitor.recheck(serverID: serverID)"))
        #expect(delivery.contains("throw ScrobbleError.invalidCredentials(provider: \"jellyfin\")"))
        #expect(delivery.contains("jellyfin.scrobble.serversReadFailed"))
    }

    @Test("the star in the Jellyfin tables goes through the one favourites queue")
    func favouritesAreWired() throws {
        let wiring = try self.source("App/JellyfinWiring.swift")
        #expect(wiring.contains("let annotations = JellyfinAnnotations(service: service)"))
        #expect(wiring.contains("annotationDelivery: annotations"))
        #expect(wiring.contains("annotations: annotations,"))
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

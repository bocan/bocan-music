import Foundation
import Testing
@testable import UI

// MARK: - MiniPlayerTransportConventionTests

/// Source-convention guards for the shared, podcast-aware Mini Player transport.
/// The views cannot be exercised host-less, so we assert the structural facts by
/// reading source: the transport branches on the podcast flag and swaps track
/// navigation for episode skip, and every layout routes through the shared control.
@Suite("Mini Player Transport Convention")
struct MiniPlayerTransportConventionTests {
    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.uiSourcesURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Transport is podcast-aware: episode skip for podcasts, track nav for music")
    func transportPodcastAware() throws {
        let transport = try self.source("MiniPlayer/MiniPlayerTransport.swift")
        #expect(transport.contains("self.np.isPodcast"))
        #expect(transport.contains("self.np.skipBack()"))
        #expect(transport.contains("self.np.skipForward()"))
        // The track-oriented controls stay on the music branch only.
        #expect(transport.contains("self.np.previous()"))
        #expect(transport.contains("self.np.next()"))
        #expect(transport.contains("self.np.toggleShuffle()"))
    }

    @Test("Every mini-player layout routes through the shared MiniPlayerTransport")
    func layoutsUseSharedTransport() throws {
        for file in [
            "MiniPlayerCompact.swift",
            "MiniPlayerSquare.swift",
            "MiniPlayerVisualizer.swift",
            "MiniPlayerView.swift",
        ] {
            let layout = try self.source("MiniPlayer/\(file)")
            #expect(layout.contains("MiniPlayerTransport("), "\(file) should use the shared MiniPlayerTransport")
        }
    }
}

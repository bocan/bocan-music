import Foundation
import Testing
@testable import UI

// MARK: - ContinueListeningRailConventionTests

/// Source-convention checks for the Continue Listening rail (ADR-054). The
/// rail's layout and tap routing cannot be exercised host-less, so these
/// assert the structural wiring: the home view mounts the rail gated on a
/// non-empty check, the rail scrolls horizontally, taps route to the view
/// model's resume, and the card stays compact (quarter-size artwork).
@Suite("Continue Listening rail source conventions")
struct ContinueListeningRailConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("home view mounts the rail gated on a non-empty check")
    func homeViewGatesRail() throws {
        let source = try self.source("Sources/UI/Browse/Podcasts/PodcastsHomeView.swift")
        let gate = try #require(source.range(of: "!self.vm.continueListening.isEmpty"))
        let mount = try #require(source.range(of: "ContinueListeningRail(vm:"))
        #expect(gate.lowerBound < mount.lowerBound, "the empty rail must leave the tree entirely")
    }

    @Test("rail scrolls horizontally and routes taps to resume")
    func railScrollsAndResumes() throws {
        let source = try self.source("Sources/UI/Browse/Podcasts/ContinueListeningRail.swift")
        #expect(source.contains("ScrollView(.horizontal"))
        #expect(source.contains("vm.resume(item)"))
    }

    @Test("card artwork stays at most a quarter of the grid cell art")
    func compactArtwork() throws {
        let source = try self.source("Sources/UI/Browse/Podcasts/ContinueListeningRail.swift")
        let match = try #require(
            source.firstMatch(of: /artSize: CGFloat = (\d+)/),
            "the rail must pin its artwork size as a named constant"
        )
        let size = try #require(Int(match.1))
        #expect(size <= 45, "rail art must be at most 0.25x the 180 pt grid art")
    }

    @Test("progress bar is omitted for unknown or zero durations")
    func progressGuard() throws {
        let source = try self.source("Sources/UI/Browse/Podcasts/ContinueListeningRail.swift")
        #expect(source.contains("duration > 0 else { return nil }"))
        #expect(source.contains("if let progress"))
    }
}

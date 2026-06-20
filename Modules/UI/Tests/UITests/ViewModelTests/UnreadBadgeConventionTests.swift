import Foundation
import Testing
@testable import UI

// MARK: - UnreadBadgeConventionTests

/// Source-convention guards for the Phase 21-12-f unread badge and grid menu:
/// the views cannot be exercised host-less, so we assert their structure by
/// reading source (the overlay placement, the non-zero gate, the a11y label,
/// the verbatim numeral, and the Mark-all menu wiring).
@Suite("Unread Badge Convention")
struct UnreadBadgeConventionTests {
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

    @Test("Grid overlays the badge at topTrailing, gated on non-zero, with an a11y label")
    func badgeOverlay() throws {
        let grid = try self.source("Browse/Podcasts/PodcastsGridView.swift")
        #expect(grid.contains(".overlay(alignment: .topTrailing)"))
        #expect(grid.contains("count > 0"))
        #expect(grid.contains("UnreadBadge(count: count)"))
        #expect(grid.contains("accessibilityLabel"))
        #expect(grid.contains("unplayed episodes"))
    }

    @Test("UnreadBadge renders a verbatim numeral, never a localized string")
    func badgeNumeral() throws {
        let badge = try self.source("Browse/Podcasts/UnreadBadge.swift")
        #expect(badge.contains("Text(verbatim:"))
        #expect(badge.contains("count.formatted()"))
    }

    @Test("Grid context menu offers Mark All as Played wired to markAllPlayed(podcastID:)")
    func markAllMenu() throws {
        let grid = try self.source("Browse/Podcasts/PodcastsGridView.swift")
        #expect(grid.contains("Mark All as Played"))
        #expect(grid.contains("markAllPlayed(podcastID: id)"))
    }
}

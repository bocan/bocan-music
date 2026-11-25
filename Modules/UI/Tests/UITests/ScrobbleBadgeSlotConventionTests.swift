import Foundation
import Testing
@testable import UI

// MARK: - ScrobbleBadgeSlotConventionTests

/// The pending-scrobbles badge sits in the same row as the progress bar. A
/// play is queued halfway through a song and sent a moment later, so when the
/// badge's slot came and went with the count, the whole strip moved and the
/// progress bar jumped under the pointer during a drag (#710). The layout
/// cannot be measured host-less, so this pins the structure: the slot depends
/// only on the main window's scrobble view model, and the count only hides it.
@Suite("Scrobble badge slot source conventions (#710)")
struct ScrobbleBadgeSlotConventionTests {
    private func source() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/AppRoot/NowPlayingPanelButtons.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the pending count never adds or removes the badge's slot")
    func countDoesNotGateTheSlot() throws {
        let source = try self.source()
        #expect(!source.contains("if self.vm.pendingScrobbleCount > 0"))
        #expect(source.contains("if self.scrobbleSettingsVM != nil {"))
    }

    @Test("an empty queue hides the badge without taking its space away")
    func emptyQueueHidesBadge() throws {
        let source = try self.source()
        for modifier in [
            ".opacity(pending ? 1 : 0)",
            ".allowsHitTesting(pending)",
            ".disabled(!pending)",
            ".accessibilityHidden(!pending)",
        ] {
            #expect(source.contains(modifier), "the badge must use \(modifier)")
        }
    }
}

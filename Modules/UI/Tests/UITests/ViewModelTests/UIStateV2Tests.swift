import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - UIStateV2Tests

/// Phase 19 step 9: regression coverage for the persisted UI state and the
/// new `SidebarSectionExpansion` field. The decoder must remain
/// forward-compatible with older blobs that pre-date the field.
@Suite("UIStateV2 + SidebarSectionExpansion")
struct UIStateV2Tests {
    // MARK: - SidebarSectionExpansion

    @Test("Defaults to every section expanded")
    func defaults() {
        let expansion = SidebarSectionExpansion()
        #expect(expansion.localLibrary == true)
        #expect(expansion.sources == true)
        #expect(expansion.recents == true)
        #expect(expansion.queue == true)
        #expect(expansion.expandedServers.isEmpty)
    }

    @Test("Round-trips through JSON with all sections collapsed and two servers expanded")
    func roundTripExpansion() throws {
        let original = try SidebarSectionExpansion(
            localLibrary: false,
            sources: false,
            recents: true,
            queue: false,
            expandedServers: [
                #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
                #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SidebarSectionExpansion.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoding an empty object yields all-true defaults (forward compatibility)")
    func forwardCompatEmpty() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(SidebarSectionExpansion.self, from: data)
        #expect(decoded == SidebarSectionExpansion())
    }

    @Test("Decoding a partial object keeps explicit false values and defaults the rest")
    func forwardCompatPartial() throws {
        let data = Data(#"{"sources": false}"#.utf8)
        let decoded = try JSONDecoder().decode(SidebarSectionExpansion.self, from: data)
        #expect(decoded.sources == false)
        #expect(decoded.localLibrary == true)
        #expect(decoded.recents == true)
        #expect(decoded.queue == true)
    }

    // MARK: - UIStateV2

    @Test("UIStateV2 round-trips sectionExpansion alongside existing fields")
    func uiStateRoundTrip() throws {
        let serverID = try #require(UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890"))
        let original = UIStateV2(
            selectedDestination: .subsonicAlbums(serverID),
            sortColumn: .title,
            sortAscending: false,
            sidebarWidth: 220,
            expandedPlaylistFolders: [42],
            sectionExpansion: SidebarSectionExpansion(
                localLibrary: false,
                sources: true,
                recents: false,
                queue: true,
                expandedServers: [serverID]
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UIStateV2.self, from: data)
        #expect(decoded.selectedDestination == .subsonicAlbums(serverID))
        #expect(decoded.sortColumn == .title)
        #expect(decoded.sortAscending == false)
        #expect(decoded.sidebarWidth == 220)
        #expect(decoded.expandedPlaylistFolders == [42])
        #expect(decoded.sectionExpansion == original.sectionExpansion)
    }

    @Test("UIStateV2 decodes legacy payloads without sectionExpansion and uses defaults")
    func uiStateLegacyDecode() throws {
        // Build a fresh payload, then strip the sectionExpansion key to
        // simulate a blob persisted by a pre-step-9 build.
        let fresh = UIStateV2(
            selectedDestination: .songs,
            sortColumn: .artist,
            sortAscending: true,
            sidebarWidth: nil,
            expandedPlaylistFolders: [],
            sectionExpansion: SidebarSectionExpansion(localLibrary: false)
        )
        let data = try JSONEncoder().encode(fresh)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "sectionExpansion")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(UIStateV2.self, from: stripped)
        #expect(decoded.sectionExpansion == SidebarSectionExpansion())
    }
}

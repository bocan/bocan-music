import Foundation
import Testing
@testable import UI

@Suite("SidebarDestination.subsonicServerID")
struct SidebarDestinationSubsonicServerIDTests {
    @Test("returns the wrapped UUID for every Subsonic case")
    func returnsUUIDForSubsonicCases() {
        let id = UUID()
        let cases: [SidebarDestination] = [
            .subsonicRoot(id),
            .subsonicSongs(id), .subsonicAlbums(id), .subsonicArtists(id),
            .subsonicGenres(id), .subsonicPlaylists(id),
            .subsonicPlaylist(id, "playlist-7"),
            .subsonicStarred(id), .subsonicRandom(id),
            .subsonicRecentlyAdded(id), .subsonicMostPlayed(id),
            .subsonicInternetRadio(id), .subsonicPodcasts(id),
            .subsonicBookmarks(id),
        ]
        for dest in cases {
            #expect(dest.subsonicServerID == id, "Expected id for \(dest)")
        }
    }

    @Test("returns nil for non-Subsonic destinations")
    func returnsNilForOtherCases() {
        let cases: [SidebarDestination] = [
            .songs, .albums, .artists, .genres, .composers,
            .recentlyAdded, .recentlyPlayed, .mostPlayed,
            .upNext, .search("query"),
        ]
        for dest in cases {
            #expect(dest.subsonicServerID == nil, "Expected nil for \(dest)")
        }
    }
}

import SwiftUI

// MARK: - SubsonicPlaceholderView

/// Phase 19 step 9 placeholder. Step 10 replaces this with the real
/// per-server browse views (Songs / Albums / Artists / Genres). The view is
/// intentionally minimal so the sidebar can route selection somewhere
/// renderable today without prescribing the future layout.
struct SubsonicPlaceholderView: View {
    let serverID: UUID
    let destination: SidebarDestination

    var body: some View {
        ContentUnavailableView(
            self.title,
            systemImage: self.symbol,
            description: Text("Phase 19 step 10 will wire this view to the Subsonic browse APIs.")
        )
        .accessibilityIdentifier("subsonic.placeholder.\(self.kind)")
    }

    private var title: String {
        switch self.destination {
        case .subsonicSongs: "Songs"
        case .subsonicAlbums: "Albums"
        case .subsonicArtists: "Artists"
        case .subsonicGenres: "Genres"
        default: "Subsonic"
        }
    }

    private var symbol: String {
        switch self.destination {
        case .subsonicSongs: "music.note"
        case .subsonicAlbums: "square.grid.2x2"
        case .subsonicArtists: "music.mic"
        case .subsonicGenres: "tag"
        default: "server.rack"
        }
    }

    private var kind: String {
        switch self.destination {
        case .subsonicSongs: "songs"
        case .subsonicAlbums: "albums"
        case .subsonicArtists: "artists"
        case .subsonicGenres: "genres"
        default: "unknown"
        }
    }
}

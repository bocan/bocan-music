import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicSongRow

/// A compact song row for use in Subsonic `List`-based views (playlists,
/// bookmarks).  Shows cover art, title, artist/album subtitle, star toggle,
/// and duration.
struct SubsonicSongRow: View {
    let song: Song
    let serverID: UUID
    let coverArtProvider: SubsonicCoverArtProvider?

    @Environment(\.subsonicAnnotationCoordinator) private var annotationCoordinator

    var body: some View {
        HStack(spacing: 10) {
            SubsonicCoverImage(
                provider: self.coverArtProvider,
                serverID: self.serverID,
                entityID: self.song.coverArt,
                seed: abs(self.song.id.hashValue),
                pixelSize: 80
            )
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.song.title)
                    .font(Typography.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                let subtitle = [self.song.artist, self.song.album]
                    .compactMap(\.self)
                    .filter { !$0.isEmpty }
                    .joined(separator: " — ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let coord = self.annotationCoordinator {
                SubsonicStarButton(song: self.song, serverID: self.serverID, coordinator: coord)
            }

            Text(Self.formatDuration(self.song.duration))
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .contextMenu {
            if let coord = self.annotationCoordinator {
                SubsonicRatingMenu(song: self.song, serverID: self.serverID, coordinator: coord)
            }
        }
    }

    static func formatDuration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - SubsonicStarButton

struct SubsonicStarButton: View {
    let song: Song
    let serverID: UUID
    @ObservedObject var coordinator: SubsonicAnnotationCoordinator

    var body: some View {
        let starred = self.coordinator.isStarred(songID: self.song.id, serverStarred: self.song.starred)
        Button {
            self.coordinator.toggleStar(
                songID: self.song.id,
                serverID: self.serverID,
                currentlyStarred: starred
            )
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .foregroundStyle(starred ? Color.starTint : Color.textTertiary)
        }
        .buttonStyle(.plain)
        .help(starred ? L10n.string("Unstar") : L10n.string("Star"))
        .accessibilityLabel(starred ? L10n.string("Unstar \(self.song.title)") : L10n.string("Star \(self.song.title)"))
    }
}

// MARK: - SubsonicRatingMenu

struct SubsonicRatingMenu: View {
    let song: Song
    let serverID: UUID
    @ObservedObject var coordinator: SubsonicAnnotationCoordinator

    var body: some View {
        let current = self.coordinator.rating(songID: self.song.id, serverRating: self.song.userRating)
        Menu(L10n.string("Rating")) {
            ForEach(0 ... 5, id: \.self) { stars in
                Button {
                    self.coordinator.setRating(
                        songID: self.song.id,
                        serverID: self.serverID,
                        newRating: stars,
                        previousRating: self.song.userRating
                    )
                } label: {
                    HStack {
                        Text(stars == 0 ? L10n.string("None") : String(repeating: "★", count: stars))
                        if stars == current { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }
}

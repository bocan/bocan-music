import Persistence
import SwiftUI

// MARK: - AlbumDetailView

/// Header (cover + metadata + play button) + track list for one album.
///
/// The track list reuses `TracksView` but hides the Album column since
/// context is already known.
public struct AlbumDetailView: View {
    public let albumID: Int64
    public var library: LibraryViewModel

    @State private var album: Album?
    @State private var artistName = ""
    @State private var artwork: NSImage?

    public init(albumID: Int64, library: LibraryViewModel) {
        self.albumID = albumID
        self.library = library
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            self.header

            Divider()

            // Track list
            TracksView(vm: self.library.tracks, library: self.library)
        }
        .task {
            await self.load()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            self.artworkView

            VStack(alignment: .leading, spacing: 6) {
                if let year = album?.year {
                    Text(verbatim: String(year))
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .textCase(.uppercase)
                }

                Text(self.album?.title ?? "")
                    .font(Typography.largeTitle)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                if !self.artistName.isEmpty {
                    Button {
                        if let artistID = album?.albumArtistID {
                            Task { await self.library.selectDestination(.artist(artistID)) }
                        }
                    } label: {
                        Text(self.artistName)
                            .font(Typography.title)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Artist: \(self.artistName)")
                }

                if let total = album?.totalTracks {
                    Text("\(total) songs")
                        .font(Typography.footnote)
                        .foregroundStyle(Color.textSecondary)
                }

                // Play / Shuffle buttons (Phase 4 audit H4).
                HStack(spacing: 8) {
                    Button {
                        Task {
                            if let first = library.tracks.tracks.first {
                                await self.library.play(track: first)
                            }
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(Typography.body)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityLabel("Play Album")
                    .help("Play this album from the first track")

                    Button {
                        Task { await self.playShuffled() }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(Typography.body)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Shuffle Album")
                    .help("Play this album in shuffled order")
                    .disabled(self.library.tracks.tracks.isEmpty)
                }
                .padding(.top, 4)
            }

            Spacer()
        }
        .padding(20)
        .background(Color.bgSecondary)
    }

    private var artworkView: some View {
        Group {
            if let img = artwork {
                // Base colour drives layout; the image is an overlay so a
                // non-square source can't stretch the 180×180 frame.
                Color.bgTertiary
                    .overlay {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    }
                    .accessibilityLabel("\(self.album?.title ?? "Album") artwork")
            } else if let path = album?.coverArtPath {
                Artwork(artPath: path, seed: Int(self.albumID), size: 180)
                    .accessibilityLabel("\(self.album?.title ?? "Album") artwork")
            } else {
                GradientPlaceholder(seed: Int(self.albumID))
                    .accessibilityLabel("\(self.album?.title ?? "Album") artwork placeholder")
            }
        }
        .frame(width: 180, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius * 2, style: .continuous))
        .shadow(radius: 8, y: 4)
    }

    // MARK: - Data loading

    private func playShuffled() async {
        let tracks = self.library.tracks.tracks
        guard !tracks.isEmpty else { return }
        await self.library.play(tracks: tracks, startingAt: 0)
        await self.library.setShuffle(true)
    }

    private func load() async {
        await self.library.tracks.load(albumID: self.albumID)

        // Resolve album record
        do {
            let repo = AlbumRepository(database: library.database)
            let rec = try await repo.fetch(id: self.albumID)
            self.album = rec
            // Resolve artist
            if let artistID = rec.albumArtistID {
                let artistRepo = ArtistRepository(database: library.database)
                if let name = try? await artistRepo.fetch(id: artistID).name {
                    self.artistName = name
                }
            }
            // Load artwork
            if let hash = rec.coverArtHash {
                let artRepo = CoverArtRepository(database: library.database)
                if let artRec = try? await artRepo.fetch(hash: hash) {
                    self.artwork = await ArtworkLoader.shared.image(at: artRec.path)
                }
            }
        } catch {
            // Non-fatal; album fields remain empty
        }
    }
}

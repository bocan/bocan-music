import SwiftUI

// MARK: - ImmersiveNowPlayingColumn

/// The leading Immersive Mode column (ADR-089): the artwork as a square that
/// fills the column width, then the title, artist and album beneath it.
/// Podcasts show the episode title and the show name; radio shows the live
/// stream title and the station name. Nothing playing shows the same idle
/// copy as the transport strip.
struct ImmersiveNowPlayingColumn: View {
    /// `@Observable`, so a plain property is the correct binding.
    var vm: NowPlayingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            self.artwork

            VStack(alignment: .leading, spacing: 6) {
                Text(self.titleText)
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(self.vm.title.isEmpty ? Color.textSecondary : Color.textPrimary)
                    .lineLimit(2)
                    .accessibilityIdentifier(A11y.Immersive.title)

                if !self.vm.artist.isEmpty {
                    Text(self.vm.artist)
                        .font(.title3)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier(A11y.Immersive.artist)
                }

                if let detail = self.detailText {
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                        .accessibilityIdentifier(A11y.Immersive.album)
                }
            }

            Spacer(minLength: 0)

            // The player controls sit under everything else in this column.
            // The strip is covered while Immersive Mode is on.
            ImmersiveTransport(np: self.vm)
        }
        .padding(20)
    }

    // MARK: - Text

    private var titleText: String {
        self.vm.title.isEmpty ? L10n.string("Not playing") : self.vm.title
    }

    /// The third line: the album for music, the station for radio. Podcasts
    /// carry the show in `artist` and nothing here.
    private var detailText: String? {
        if let station = self.vm.nowPlayingRadioStationName, !station.isEmpty {
            return station
        }
        return self.vm.album.isEmpty ? nil : self.vm.album
    }

    // MARK: - Artwork

    /// A fixed-aspect base with the image in an overlay, the same trick as
    /// ``Artwork``, so a non-square embedded cover cannot distort the column.
    private var artwork: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = self.vm.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    GradientPlaceholder(seed: Int(truncatingIfNeeded: self.vm.nowPlayingAlbumID ?? 0))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium, style: .continuous))
            .accessibilityLabel(
                self.vm.title.isEmpty ? L10n.string("No artwork") : L10n.string("Artwork for \(self.vm.title)")
            )
            .accessibilityIdentifier(A11y.Immersive.artwork)
    }
}

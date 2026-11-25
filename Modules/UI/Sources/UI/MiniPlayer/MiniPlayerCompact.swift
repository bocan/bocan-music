import AppKit
import SwiftUI

// MARK: - MiniPlayerCompact

/// Horizontal compact layout: thumbnail | title+artist | transport+scrubber.
/// Used when width ≥ 300 and height < 220.
struct MiniPlayerCompact: View {
    @ObservedObject var vm: MiniPlayerViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"

    private var np: NowPlayingViewModel {
        self.vm.nowPlaying
    }

    var body: some View {
        HStack(spacing: 10) {
            self.artworkThumbnail

            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(
                    self.np.title.isEmpty ? L10n.string("Not playing") : self.np.title,
                    font: .system(size: 12, weight: .semibold),
                    foregroundStyle: self.np.title.isEmpty ? Color.textSecondary : Color.textPrimary
                )

                if !self.np.artist.isEmpty {
                    MarqueeText(
                        self.np.artist,
                        font: .system(size: 11),
                        foregroundStyle: Color.textSecondary
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            MiniPlayerTransport(
                np: self.np,
                musicLayout: .full,
                identifiers: .miniPlayer,
                openInfoWindow: { self.openWindow(id: "track-info") },
                spacing: 12,
                secondarySize: 14,
                primarySize: 18,
                accentSize: 12
            )

            self.scrubberStack

            // Balances the title's greedy leading frame above. It must be the SAME
            // construct (.frame(maxWidth: .infinity)), not a Spacer: a Spacer is a
            // weaker claim and collapses next to a .frame(maxWidth: .infinity)
            // sibling, leaving the controls pinned right. Two equal frames split the
            // slack 50/50, centring the transport + scrubber group.
            Color.clear.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Sub-views

    private var artworkThumbnail: some View {
        Group {
            if let img = self.np.artwork {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                GradientPlaceholder(seed: 1)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private var scrubberStack: some View {
        PlaybackPositionSlider(
            nowPlaying: self.np,
            style: PositionSliderStyle(rebuildKey: self.accentColorKey)
        ) { slider, position in
            VStack(spacing: 2) {
                slider
                    .frame(width: 80)

                HStack {
                    Text(Formatters.duration(position))
                    Spacer()
                    Text(Formatters.duration(self.np.duration))
                }
                .scaledSystemFont(size: 9)
                .foregroundStyle(Color.textTertiary)
                .frame(width: 80)
                .monospacedDigit()
                // The 80 pt strip holds two h:mm:ss readings at 9 pt with room to
                // spare; a ten-hour audiobook overruns it. Truncate rather than
                // wrap the pair onto a second line (#563).
                .lineLimit(1)
            }
        }
    }
}

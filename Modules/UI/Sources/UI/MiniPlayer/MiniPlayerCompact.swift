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
    @State private var dragPosition: Double?

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
                    .aspectRatio(contentMode: .fill)
            } else {
                GradientPlaceholder(seed: 1)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private var scrubberStack: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { self.dragPosition ?? (self.np.duration > 0 ? self.np.position / self.np.duration : 0) },
                    set: { self.dragPosition = $0 }
                ),
                in: 0 ... 1
            ) { editing in
                if !editing, let fraction = self.dragPosition {
                    self.dragPosition = nil
                    Task { await self.np.scrub(to: fraction * self.np.duration) }
                }
            }
            .controlSize(.mini)
            .frame(width: 80)
            .id(self.accentColorKey)
            .disabled(self.np.duration == 0)
            .help(L10n.string("Scrub to position"))
            .accessibilityLabel(L10n.string("Playback position"))

            HStack {
                Text(Formatters.duration(self.dragPosition.map { $0 * self.np.duration } ?? self.np.position))
                Spacer()
                Text(Formatters.duration(self.np.duration))
            }
            .scaledSystemFont(size: 9)
            .foregroundStyle(Color.textTertiary)
            .frame(width: 80)
            .monospacedDigit()
        }
    }
}

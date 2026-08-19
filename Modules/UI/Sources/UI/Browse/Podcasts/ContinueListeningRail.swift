import Persistence
import SwiftUI

// MARK: - ContinueListeningRail

/// One horizontal row of compact resume cards at the top of the Podcasts home
/// view (ADR-054): the episodes the user has started but not finished, across
/// every subscribed show, newest activity first. Tapping a card resumes at
/// the saved position through the normal play path. The home view mounts the
/// rail only when `vm.continueListening` is non-empty, so it has no empty
/// state of its own.
///
/// Deliberately low-profile: the artwork is a quarter of the grid's cell art
/// (44 pt vs 180 pt), laid out lead-image style so the whole rail costs about
/// one row of text more than a section header.
struct ContinueListeningRail: View {
    @ObservedObject var vm: PodcastsViewModel

    /// Card artwork side; ~0.25x of `Theme.albumGridMinWidth` grid art.
    private static let artSize: CGFloat = 44
    private static let cardWidth: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized: "Continue Listening")
                .font(Typography.subheadline)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(self.vm.continueListening) { item in
                        ContinueListeningCard(item: item, artSize: Self.artSize)
                            .frame(width: Self.cardWidth)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await self.vm.resume(item) }
                            }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - ContinueListeningCard

/// A single resume card: small square artwork, episode title over show title,
/// and a thin progress bar. Feed content is verbatim, never localized.
private struct ContinueListeningCard: View {
    let item: ContinueListeningItem
    let artSize: CGFloat

    /// Fractional progress, or nil when the duration is unknown or zero.
    private var progress: Double? {
        guard let duration = self.item.duration, duration > 0 else { return nil }
        return min(max(self.item.playPosition / duration, 0), 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            Artwork(
                artPath: self.item.artworkPath,
                seed: Int(self.item.podcastID),
                size: self.artSize
            )
            .frame(width: self.artSize, height: self.artSize)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.item.episodeTitle)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                Text(self.item.showTitle)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Resume \(self.item.episodeTitle)"))
        .accessibilityHint(L10n.string("Double-tap to resume episode"))
        .accessibilityAddTraits(.isButton)
    }
}

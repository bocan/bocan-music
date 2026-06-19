import Persistence
import SwiftUI

// MARK: - PodcastsGridView

/// An adaptive `LazyVGrid` of subscribed shows, styled like `AlbumsGridView`.
///
/// Clicking a cell calls `vm.openShow(_:)`, which publishes `selectedShowID`;
/// the `onChange` below translates that into `library.selectDestination(.podcastShow(id))`.
struct PodcastsGridView: View {
    @ObservedObject var vm: PodcastsViewModel
    var library: LibraryViewModel

    @ScaledMetric(relativeTo: .body) private var scaledMinWidth = Theme.albumGridMinWidth

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: self.scaledMinWidth), spacing: Theme.albumGridSpacing)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: self.columns, spacing: Theme.albumGridSpacing) {
                ForEach(self.vm.subscribed, id: \.feedURL) { podcast in
                    PodcastCell(
                        podcast: podcast,
                        episodeCount: podcast.id.flatMap { self.vm.podcastEpisodeCounts[$0] }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let id = podcast.id { self.vm.openShow(id) }
                    }
                    .contextMenu { self.contextMenu(for: podcast) }
                }
            }
            .padding(Theme.albumGridSpacing)
        }
        .onChange(of: self.vm.selectedShowID) { _, newID in
            if let id = newID {
                self.vm.selectedShowID = nil
                Task { await self.library.selectDestination(.podcastShow(id)) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for podcast: Podcast) -> some View {
        if let id = podcast.id {
            Button(L10n.string("Refresh")) {
                Task {
                    do {
                        try await self.library.podcastActions?.refresh(podcastID: id)
                    } catch {
                        // Toast or silent log; errors are handled by the service.
                    }
                }
            }
            Divider()
            Button(L10n.string("Unsubscribe"), role: .destructive) {
                Task { await self.vm.unsubscribe(id) }
            }
        }
    }
}

// MARK: - PodcastCell

/// A single podcast cell: artwork + title + author + episode count. Feed content is verbatim.
private struct PodcastCell: View {
    let podcast: Podcast
    let episodeCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let path = self.podcast.artworkPath {
                    Artwork(
                        artPath: path,
                        seed: Int(self.podcast.id ?? 0),
                        size: Theme.albumGridMinWidth
                    )
                    .accessibilityLabel(
                        L10n.string("\(self.podcast.title) artwork")
                    )
                } else {
                    GradientPlaceholder(seed: Int(self.podcast.id ?? 0))
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: Theme.artworkCornerRadius,
                                style: .continuous
                            )
                        )
                        .accessibilityLabel(
                            L10n.string("\(self.podcast.title) artwork placeholder")
                        )
                }
            }
            .frame(maxWidth: .infinity)

            // Feed content -- not localized.
            Text(self.podcast.title)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            Text(self.podcast.author ?? "")
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)

            if let count = self.episodeCount {
                Text(L10n.string("\(count) episodes"))
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [self.podcast.title, self.podcast.author].compactMap(\.self).joined(separator: ", ")
        )
        .accessibilityHint(L10n.string("Double-tap to open podcast"))
        .accessibilityAddTraits(.isButton)
    }
}

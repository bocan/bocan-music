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

    /// Identifiable wrapper so the settings sheet is driven by `.sheet(item:)`.
    private struct SettingsTarget: Identifiable {
        let podcast: Podcast
        var id: Int64 {
            self.podcast.id ?? -1
        }
    }

    @State private var settingsTarget: SettingsTarget?
    /// Programmatic scroll position, used to restore the grid offset on return
    /// from a show (#349).
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// Live vertical scroll offset, snapshotted into the view model when opening
    /// a show so it survives the grid rebuild.
    @State private var liveScrollOffset: CGFloat = 0

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: self.scaledMinWidth), spacing: Theme.albumGridSpacing)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: self.columns, spacing: Theme.albumGridSpacing) {
                ForEach(self.vm.subscribed, id: \.feedURL) { podcast in
                    PodcastCell(
                        podcast: podcast,
                        episodeCount: podcast.id.flatMap { self.vm.podcastEpisodeCounts[$0] },
                        unreadCount: podcast.id.flatMap { self.vm.podcastUnplayedCounts[$0] }
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
        .scrollPosition(self.$scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, newY in
            self.liveScrollOffset = newY
        }
        .onChange(of: self.vm.selectedShowID) { _, newID in
            if let id = newID {
                self.vm.selectedShowID = nil
                // Snapshot the current scroll offset so the grid returns to it
                // when it's rebuilt on the way back (#349).
                self.vm.gridScrollOffset = Double(self.liveScrollOffset)
                Task { await self.library.selectDestination(.podcastShow(id)) }
            }
        }
        // Restore the saved offset when the grid (re)appears or the list reloads,
        // so returning from a show lands where the user left off (#349).
        .onAppear { self.restoreScrollOffset() }
        .onChange(of: self.vm.subscribed.map(\.feedURL)) { _, _ in self.restoreScrollOffset() }
        .sheet(item: self.$settingsTarget) { target in
            PodcastShowSettingsView(podcast: target.podcast, vm: self.vm)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SortMenu(selection: self.sortBinding, help: L10n.string("Choose how podcasts are sorted"))
            }
        }
    }

    /// Bridges the sort menu to the view model, which owns and persists the
    /// preference and re-sorts in place on change.
    private var sortBinding: Binding<PodcastSortOrder> {
        Binding(
            get: { self.vm.sortOrder },
            set: { self.vm.setSortOrder($0) }
        )
    }

    /// Restores the podcasts grid to its saved scroll offset (#349).
    private func restoreScrollOffset() {
        guard self.vm.gridScrollOffset > 0 else { return }
        self.scrollPosition.scrollTo(y: CGFloat(self.vm.gridScrollOffset))
    }

    @ViewBuilder
    private func contextMenu(for podcast: Podcast) -> some View {
        if let id = podcast.id {
            Button(L10n.string("Get Info")) {
                if let url = URL(string: podcast.feedURL) {
                    Task { await self.vm.openDetailForURL(url) }
                }
            }
            Divider()
            Button(L10n.string("Refresh")) {
                Task {
                    do {
                        try await self.library.podcastActions?.refresh(podcastID: id)
                    } catch {
                        // Toast or silent log; errors are handled by the service.
                    }
                }
            }
            // Marks every episode played, clearing the unread badge via the
            // state observation. This stamps completed_at, which starts the
            // 30-day transcript cleanup clock (phase 21-12-b) for each episode.
            Button(L10n.string("Mark All as Played")) {
                Task { await self.library.podcastActions?.markAllPlayed(podcastID: id) }
            }
            Button(L10n.string("Show Settings…")) {
                self.settingsTarget = SettingsTarget(podcast: podcast)
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
    let unreadCount: Int?

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
            .overlay(alignment: .topTrailing) {
                if let count = self.unreadCount, count > 0 {
                    UnreadBadge(count: count)
                        .padding(6)
                        .accessibilityLabel(L10n.string("\(count) unplayed episodes"))
                }
            }

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

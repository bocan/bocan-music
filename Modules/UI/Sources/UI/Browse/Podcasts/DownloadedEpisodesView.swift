import Persistence
import SwiftUI

// MARK: - DownloadedEpisodesView

/// Every downloaded episode across all shows (#651): the Downloaded side of
/// the Podcasts toolbar switch. A bar of list controls sits over a table, so
/// the view costs one row more than the show page's episode list.
///
/// Play All, Play Next and Add to Queue put episodes into Up Next, which
/// already takes podcast items, so "play my downloads in order" needs no
/// playlist.
struct DownloadedEpisodesView: View {
    @ObservedObject var vm: PodcastsViewModel
    var library: LibraryViewModel
    /// The toolbar search query, matched on episode and show title.
    var searchQuery: String

    /// The clicked column heading, stored as a string (see `DownloadedSort`):
    /// `KeyPathComparator` cannot go into `@AppStorage` itself.
    @AppStorage("podcasts.downloads.sort") private var sortRaw = ""
    @AppStorage("podcasts.downloads.groupByShow") private var groupByShow = false
    @State private var selection = Set<EpisodeListItem.ID>()

    /// The Table's sort, read from and written to the stored string, so the
    /// heading the listener clicked survives a relaunch.
    private var sortOrder: Binding<[KeyPathComparator<DownloadedRow>]> {
        Binding(
            get: { DownloadedSort.order(from: self.sortRaw) },
            set: { self.sortRaw = DownloadedSort.rawValue(for: $0) }
        )
    }

    private var visible: [DownloadedRow] {
        PodcastsViewModel.visibleDownloads(
            self.vm.downloaded,
            showFilter: self.vm.downloadedShowFilter,
            query: self.searchQuery,
            sortOrder: DownloadedSort.order(from: self.sortRaw),
            showTitles: self.vm.showTitles
        )
    }

    var body: some View {
        // Computed once per render: the table, the bar and the menus all read it.
        let visible = self.visible
        let groups = self.groupByShow ? PodcastsViewModel.groupedDownloads(visible) : []
        // What Play All and the menus act on, in the order the rows appear.
        let listed = self.groupByShow ? groups.flatMap(\.rows) : visible
        VStack(spacing: 0) {
            self.controlBar(listed.map(\.item))
            Divider()
            if self.vm.downloaded.isEmpty {
                EmptyState(
                    symbol: "arrow.down.circle",
                    title: L10n.string("No Downloads"),
                    message: L10n.string("Episodes you download appear here, ready to play offline.")
                )
            } else if listed.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass",
                    title: L10n.string("No Results"),
                    message: L10n.string("No downloaded episodes match this filter.")
                )
            } else {
                self.table(flat: visible, groups: groups, listed: listed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await self.vm.observeDownloaded() }
    }

    // MARK: - Control bar

    private func controlBar(_ listed: [EpisodeListItem]) -> some View {
        HStack(spacing: 12) {
            self.listControls

            Spacer(minLength: 8)

            Text(Self.summary(listed))
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
                .lineLimit(1)

            Button {
                Task { await self.vm.playAll(listed) }
            } label: {
                Label(L10n.string("Play All"), systemImage: "play.fill")
            }
            .help(L10n.string("Replace Up Next with every listed episode you have not finished, in list order"))
            .disabled(PodcastsViewModel.episodesToPlayAll(listed).isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// Show filter and grouping: what the list holds. The column headings
    /// sort it.
    @ViewBuilder
    private var listControls: some View {
        Picker(L10n.string("Show"), selection: self.$vm.downloadedShowFilter) {
            Text(localized: "All Shows").tag(Int64?.none)
            Divider()
            ForEach(self.vm.showsWithDownloads, id: \.feedURL) { show in
                Text(verbatim: show.title).tag(show.id)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(L10n.string("List the downloads of one show, or of every show"))

        Toggle(L10n.string("Group by Show"), isOn: self.$groupByShow)
            .toggleStyle(.checkbox)
            .help(L10n.string("Gather each show's downloads under its name, shows in title order"))
    }

    /// "12 episodes · 1.3 GB", from the same key the Library Summary uses.
    private static func summary(_ items: [EpisodeListItem]) -> String {
        let bytes = items.reduce(Int64(0)) { $0 + ($1.state?.downloadBytes ?? 0) }
        return L10n.string("\(items.count.formatted()) episodes · \(bytes.formatted(.byteCount(style: .file)))")
    }

    // MARK: - Table

    /// Every column but the status badge sorts on a click of its heading;
    /// grouped, the sort applies inside each show.
    private func table(
        flat: [DownloadedRow],
        groups: [DownloadedShowGroup],
        listed: [DownloadedRow]
    ) -> some View {
        Table(of: DownloadedRow.self, selection: self.$selection, sortOrder: self.sortOrder) {
            TableColumn("") { (row: DownloadedRow) in
                EpisodeStatusIndicator(item: row.item, downloadFraction: nil)
                    .frame(width: 16, alignment: .center)
            }
            .width(28)

            TableColumn(L10n.string("Episode"), value: \DownloadedRow.title, comparator: .localizedStandard) { row in
                Text(verbatim: row.title)
                    .lineLimit(1)
            }

            TableColumn(L10n.string("Show"), value: \DownloadedRow.showTitle, comparator: .localizedStandard) { row in
                Text(verbatim: row.showTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 150, max: 260)

            TableColumn(L10n.string("Published"), value: \DownloadedRow.published) { row in
                if let ts = row.item.episode.publishedAt {
                    Text(Date(timeIntervalSince1970: ts), style: .date)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "")
                }
            }
            .width(min: 95, ideal: 115, max: 170)

            TableColumn(L10n.string("Length"), value: \DownloadedRow.length) { row in
                Text(verbatim: durationLabel(row.item))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 115, max: 150)
        } rows: {
            self.rows(flat: flat, groups: groups)
        }
        .contextMenu(
            forSelectionType: EpisodeListItem.ID.self,
            menu: { ids in self.contextMenuItems(listed.map(\.item).filter { ids.contains($0.id) }) },
            primaryAction: { ids in
                guard let row = listed.first(where: { ids.contains($0.id) }) else { return }
                Task { await self.vm.play(row.item) }
            }
        )
    }

    /// One flat run of rows, or one section per show under its title.
    @TableRowBuilder<DownloadedRow>
    private func rows(flat: [DownloadedRow], groups: [DownloadedShowGroup]) -> some TableRowContent<DownloadedRow> {
        if self.groupByShow {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { TableRow($0) }
                } header: {
                    Text(verbatim: group.title)
                }
            }
        } else {
            ForEach(flat) { TableRow($0) }
        }
    }

    // MARK: - Context menu

    /// Menu items act on the selection in list order. Controls inside a menu
    /// get no tooltip on macOS, so they carry no `.help()`.
    @ViewBuilder
    private func contextMenuItems(_ items: [EpisodeListItem]) -> some View {
        if !items.isEmpty {
            if items.count == 1, let item = items.first {
                Button(L10n.string("Play")) {
                    Task { await self.vm.play(item) }
                }
            }
            Button(L10n.string("Play Next")) {
                Task { await self.vm.enqueue(items, placement: .next) }
            }
            Button(L10n.string("Add to Queue")) {
                Task { await self.vm.enqueue(items, placement: .last) }
            }
            Divider()
            self.playStateMenuItems(items)
            Divider()
            Button(items.count == 1 ? L10n.string("Remove Download") : L10n.string("Remove Downloads")) {
                Task { await self.vm.removeDownloads(items) }
            }
            if items.count == 1, let item = items.first {
                Divider()
                Button(L10n.string("Go to Show")) {
                    self.vm.openShow(item.episode.podcastID)
                }
            }
        }
    }

    /// Mark played / unplayed, each shown only when it would change something,
    /// worded as the show page words them for one row or a selection.
    @ViewBuilder
    private func playStateMenuItems(_ items: [EpisodeListItem]) -> some View {
        let toPlay = PodcastsViewModel.episodesToMarkPlayed(items)
        let toUnplay = PodcastsViewModel.episodesToMarkUnplayed(items)
        if !toPlay.isEmpty {
            Button(items.count == 1 ? L10n.string("Mark as Played") : L10n.string("Mark Selected as Played")) {
                Task { await self.vm.setPlayed(true, episodes: toPlay) }
            }
        }
        if !toUnplay.isEmpty {
            Button(items.count == 1 ? L10n.string("Mark as Unplayed") : L10n.string("Mark Selected as Unplayed")) {
                Task { await self.vm.setPlayed(false, episodes: toUnplay) }
            }
        }
    }
}

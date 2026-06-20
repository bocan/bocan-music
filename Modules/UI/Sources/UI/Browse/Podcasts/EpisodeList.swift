import AppKit
import Persistence
import SwiftUI

// MARK: - EpisodeList

struct EpisodeList: View {
    @ObservedObject var vm: PodcastsViewModel

    @State private var selection = Set<EpisodeListItem.ID>()
    @State private var filterText = ""
    @State private var showingNotes = false

    private var filtered: [EpisodeListItem] {
        guard !self.filterText.isEmpty else { return self.vm.episodes }
        return self.vm.episodes.filter {
            $0.episode.title.localizedCaseInsensitiveContains(self.filterText)
        }
    }

    private var selectedItem: EpisodeListItem? {
        guard self.selection.count == 1, let id = selection.first else { return nil }
        return self.vm.episodes.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(L10n.string("Filter episodes"), text: self.$filterText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 6)
            Divider()
            Table(self.filtered, selection: self.$selection) {
                TableColumn("") { (item: EpisodeListItem) in
                    EpisodeStatusIndicator(item: item)
                        .frame(width: 16, alignment: .center)
                }
                .width(28)

                TableColumn(L10n.string("Episode")) { (item: EpisodeListItem) in
                    Text(verbatim: item.episode.title)
                        .lineLimit(1)
                }

                TableColumn(L10n.string("Published")) { (item: EpisodeListItem) in
                    if let ts = item.episode.publishedAt {
                        Text(Date(timeIntervalSince1970: ts), style: .date)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: "")
                    }
                }
                .width(min: 80, ideal: 100, max: 160)

                TableColumn(L10n.string("Length")) { (item: EpisodeListItem) in
                    Text(verbatim: durationLabel(item))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 80, max: 96)
            }
            .contextMenu(
                forSelectionType: EpisodeListItem.ID.self,
                menu: { ids in self.contextMenuItems(ids: ids) },
                primaryAction: { ids in
                    guard let id = ids.first,
                          let item = self.vm.episodes.first(where: { $0.id == id }),
                          let podcast = self.vm.currentShow else { return }
                    Task { await self.vm.actions?.play(episode: item, podcast: podcast) }
                }
            )
        }
        .sheet(isPresented: self.$showingNotes) {
            ShowNotesView(episode: self.selectedItem)
                .frame(minWidth: 500, minHeight: 300)
        }
    }

    @ViewBuilder
    private func contextMenuItems(ids: Set<EpisodeListItem.ID>) -> some View {
        if ids.count == 1, let id = ids.first,
           let item = self.vm.episodes.first(where: { $0.id == id }),
           let podcast = self.vm.currentShow {
            Button(L10n.string("Play")) {
                Task { await self.vm.actions?.play(episode: item, podcast: podcast) }
            }
            Divider()
            let isPlayed = item.state?.playState == .played
            if isPlayed {
                Button(L10n.string("Mark as Unplayed")) {
                    Task {
                        await self.vm.actions?.markUnplayed(
                            podcastID: item.episode.podcastID,
                            guid: item.episode.guid
                        )
                    }
                }
            } else {
                Button(L10n.string("Mark as Played")) {
                    Task {
                        await self.vm.actions?.markPlayed(
                            podcastID: item.episode.podcastID,
                            guid: item.episode.guid
                        )
                    }
                }
            }
            Divider()
            if let link = item.episode.link, let url = URL(string: link) {
                Button(L10n.string("Copy Episode Link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
                Button(L10n.string("Go to Website")) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button(L10n.string("Copy Audio URL")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.episode.audioURL, forType: .string)
            }
            Divider()
            Button(L10n.string("Show Notes")) {
                self.selection = ids
                self.showingNotes = true
            }
        }
    }
}

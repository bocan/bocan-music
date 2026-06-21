import AppKit
import Persistence
import SwiftUI

// MARK: - EpisodeList

struct EpisodeList: View {
    @ObservedObject var vm: PodcastsViewModel

    @State private var selection = Set<EpisodeListItem.ID>()
    @State private var filterText = ""
    @State private var showingNotes = false
    @State private var showingTranscript = false

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
                .width(min: 95, ideal: 115, max: 170)

                TableColumn(L10n.string("Length")) { (item: EpisodeListItem) in
                    Text(verbatim: durationLabel(item))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(min: 90, ideal: 115, max: 150)
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
        .sheet(isPresented: self.$showingTranscript) {
            if let item = self.selectedItem {
                TranscriptView(title: item.episode.title) {
                    await self.vm.loadTranscript(
                        podcastID: item.episode.podcastID,
                        guid: item.episode.guid
                    )
                }
                .frame(minWidth: 625, minHeight: 300)
            }
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
            self.downloadButton(item: item)
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
            self.notesButtons(item: item, ids: ids)
        } else if ids.count > 1 {
            self.bulkMenuItems(ids: ids)
        }
    }

    /// Download / remove for a single episode, labelled by its current state.
    /// `removeDownload` doubles as cancel for queued or in-flight downloads.
    @ViewBuilder
    private func downloadButton(item: EpisodeListItem) -> some View {
        switch item.state?.downloadState ?? .none {
        case .downloaded:
            Button(L10n.string("Remove Download")) {
                Task { await self.vm.actions?.removeDownload(podcastID: item.episode.podcastID, guid: item.episode.guid) }
            }

        case .queued, .downloading:
            Button(L10n.string("Cancel Download")) {
                Task { await self.vm.actions?.removeDownload(podcastID: item.episode.podcastID, guid: item.episode.guid) }
            }

        case .none, .failed:
            Button(L10n.string("Download")) {
                Task { await self.vm.actions?.download(podcastID: item.episode.podcastID, guid: item.episode.guid) }
            }
        }
    }

    /// Bulk actions over a multi-row selection: download every episode that is not
    /// already downloaded, or remove every one that is.
    @ViewBuilder
    private func bulkMenuItems(ids: Set<EpisodeListItem.ID>) -> some View {
        let items = self.vm.episodes.filter { ids.contains($0.id) }
        let pending = items.filter { ($0.state?.downloadState ?? .none) != .downloaded }
        let downloaded = items.filter { ($0.state?.downloadState ?? .none) == .downloaded }
        if !pending.isEmpty {
            Button(L10n.string("Download Selected")) {
                Task {
                    for item in pending {
                        await self.vm.actions?.download(podcastID: item.episode.podcastID, guid: item.episode.guid)
                    }
                }
            }
        }
        if !downloaded.isEmpty {
            Button(L10n.string("Remove Downloads")) {
                Task {
                    for item in downloaded {
                        await self.vm.actions?.removeDownload(podcastID: item.episode.podcastID, guid: item.episode.guid)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func notesButtons(item: EpisodeListItem, ids: Set<EpisodeListItem.ID>) -> some View {
        Button(L10n.string("Show Notes")) {
            self.selection = ids
            self.showingNotes = true
        }
        if item.episode.transcriptURL != nil {
            Button(L10n.string("Transcript")) {
                self.selection = ids
                self.showingTranscript = true
            }
        }
    }
}

import AppKit
import Persistence
import SwiftUI

// MARK: - PodcastShowView

/// Full episode list for a subscribed show, built in phase 21-9.
public struct PodcastShowView: View {
    @ObservedObject public var vm: PodcastsViewModel
    public var library: LibraryViewModel
    public var podcastID: Int64

    @State private var showingUnsubscribeConfirm = false

    public init(vm: PodcastsViewModel, library: LibraryViewModel, podcastID: Int64) {
        self.vm = vm
        self.library = library
        self.podcastID = podcastID
    }

    public var body: some View {
        EpisodeList(vm: self.vm)
            .task { await self.vm.loadShow(self.podcastID) }
            .navigationTitle(self.vm.currentShow?.title ?? L10n.string("Podcast"))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    self.autoDownloadToggle
                    self.moreMenu
                }
            }
            .confirmationDialog(
                L10n.string("Unsubscribe from this podcast?"),
                isPresented: self.$showingUnsubscribeConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.string("Unsubscribe"), role: .destructive) {
                    Task {
                        await self.vm.unsubscribe(self.podcastID)
                        await self.library.selectDestination(.podcasts)
                    }
                }
                Button(L10n.string("Cancel"), role: .cancel) {}
            }
    }

    @ViewBuilder
    private var autoDownloadToggle: some View {
        if let show = vm.currentShow {
            Toggle(
                L10n.string("Auto-Download"),
                isOn: Binding(
                    get: { show.autoDownload },
                    set: { on in Task { await self.vm.toggleAutoDownload(on) } }
                )
            )
            .toggleStyle(.checkbox)
            .help(L10n.string("Auto-Download"))
        }
    }

    private var moreMenu: some View {
        Menu {
            Button(L10n.string("Mark All as Played")) {
                Task { await self.vm.markAllPlayed() }
            }
            Divider()
            Button(L10n.string("Refresh")) {
                Task { await self.vm.refreshCurrentShow() }
            }
            if let show = vm.currentShow, let link = show.link, let url = URL(string: link) {
                Button(L10n.string("Go to Website")) {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button(L10n.string("Unsubscribe"), role: .destructive) {
                self.showingUnsubscribeConfirm = true
            }
        } label: {
            Label(L10n.string("More"), systemImage: "ellipsis.circle")
        }
    }
}

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
    @State private var pendingFunding: FundingLink?
    @State private var showingSettings = false

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
                    self.fundingButton
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
            .confirmationDialog(
                L10n.string("Open this funding link?"),
                isPresented: Binding(
                    get: { self.pendingFunding != nil },
                    set: { if !$0 { self.pendingFunding = nil } }
                ),
                titleVisibility: .visible,
                presenting: self.pendingFunding
            ) { link in
                Button(L10n.string("Open in Browser")) { link.open() }
                Button(L10n.string("Cancel"), role: .cancel) { self.pendingFunding = nil }
            } message: { link in
                Text(L10n.string("This opens \(link.host) in your default browser."))
            }
            .sheet(isPresented: self.$showingSettings) {
                if let show = self.vm.currentShow {
                    PodcastShowSettingsView(podcast: show, vm: self.vm)
                }
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
            .fixedSize()
            .help(L10n.string("Auto-Download"))
        }
    }

    private var fundingLink: FundingLink? {
        FundingLink(rawURL: self.vm.currentShow?.fundingURL, label: self.vm.currentShow?.fundingText)
    }

    @ViewBuilder
    private var fundingButton: some View {
        if let link = self.fundingLink {
            Button {
                self.pendingFunding = link
            } label: {
                if let label = link.label {
                    Label { Text(verbatim: label) } icon: { Image(systemName: "heart.circle") }
                } else {
                    Label(L10n.string("Support This Show"), systemImage: "heart.circle")
                }
            }
            .help(L10n.string("Support this show in your browser"))
            .accessibilityLabel(L10n.string("Support this show in your browser"))
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
            Button(L10n.string("Show Settings…")) {
                self.showingSettings = true
            }
            if let show = vm.currentShow, let link = show.link, let url = URL(string: link) {
                Button(L10n.string("Go to Website")) {
                    NSWorkspace.shared.open(url)
                }
            }
            if let link = self.fundingLink {
                Button(L10n.string("Support This Show")) {
                    self.pendingFunding = link
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

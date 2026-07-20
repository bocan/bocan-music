import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicPodcastsViewModel

/// Drives the per-server Podcasts destination (Phase 19 step 11).
///
/// Capability-gated by `SubsonicCapabilities.supportsPodcasts`. Playback of
/// podcast episodes is out of scope for this step — the view is read-only.
@MainActor
public final class SubsonicPodcastsViewModel: ObservableObject {
    public let serverID: UUID

    @Published public private(set) var channels: [PodcastChannel] = []
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    private let log = AppLogger.make(.ui)

    public init(serverID: UUID, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self.dataSource = dataSource
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            self.channels = try await self.dataSource.getPodcasts(serverID: self.serverID)
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.podcasts.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load podcasts.")
        }
    }
}

// MARK: - SubsonicPodcastsView

public struct SubsonicPodcastsView: View {
    public let serverID: UUID
    public let coverArtProvider: SubsonicCoverArtProvider?

    @StateObject private var vm: SubsonicPodcastsViewModel

    public init(
        serverID: UUID,
        dataSource: any SubsonicBrowseDataSource,
        coverArtProvider: SubsonicCoverArtProvider?
    ) {
        self.serverID = serverID
        self.coverArtProvider = coverArtProvider
        self._vm = StateObject(
            wrappedValue: SubsonicPodcastsViewModel(serverID: serverID, dataSource: dataSource)
        )
    }

    public var body: some View {
        Group {
            if self.vm.channels.isEmpty, !self.vm.isLoading {
                ContentUnavailableView(
                    L10n.string("No Podcasts"),
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text(localized: "This server has no podcast subscriptions.")
                )
            } else {
                List {
                    ForEach(self.vm.channels, id: \.id) { channel in
                        Section {
                            ForEach(channel.episode, id: \.id) { episode in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(episode.title)
                                        .font(Typography.subheadline)
                                        .foregroundStyle(Color.textPrimary)
                                        .lineLimit(1)
                                    if let desc = episode.description, !desc.isEmpty {
                                        Text(desc)
                                            .font(Typography.caption)
                                            .foregroundStyle(Color.textSecondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        } header: {
                            HStack(spacing: 10) {
                                SubsonicCoverImage(
                                    provider: self.coverArtProvider,
                                    serverID: self.serverID,
                                    entityID: channel.coverArt,
                                    seed: abs(channel.id.hashValue),
                                    pixelSize: 80
                                )
                                .frame(width: 32, height: 32)
                                Text(channel.title)
                                    .font(Typography.subheadline)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(L10n.string("Podcasts"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await self.vm.load() } } label: {
                    Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading)
            }
        }
        .task(id: self.serverID) {
            if self.vm.channels.isEmpty { await self.vm.load() }
        }
        .loadErrorAlert(L10n.string("Couldn't load podcasts"), message: self.$vm.errorMessage)
    }
}

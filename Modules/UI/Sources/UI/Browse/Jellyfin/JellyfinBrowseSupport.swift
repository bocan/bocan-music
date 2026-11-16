import Jellyfin
import SwiftUI

// MARK: - JellyfinSongListTable

/// The Jellyfin song table for any `JellyfinSongListModel`. Every view that
/// shows one server's songs builds it, so the wiring of play, paging and the
/// version-gated rows lives in one place.
struct JellyfinSongListTable: View {
    @ObservedObject var model: JellyfinSongListModel
    let library: LibraryViewModel
    let coverArtProvider: JellyfinCoverArtProvider?
    var hasMorePages = false
    var loadMore: () -> Void = {}

    var body: some View {
        JellyfinSongTable(
            rows: self.model.rows,
            rowsVersion: self.model.rowsVersion,
            isLoading: self.model.isLoading,
            hasMorePages: self.hasMorePages,
            coverArtProvider: self.coverArtProvider,
            showsSource: false,
            nowPlayingRowID: self.library.nowPlaying.jellyfinRowID,
            actions: JellyfinSongTableActions(
                playNow: { index in
                    let songs = self.model.songs
                    let serverID = self.model.serverID
                    Task { await self.library.play(jellyfinSongs: songs, serverID: serverID, startingAt: index) }
                },
                loadMore: self.loadMore,
                toggleStar: self.library.jellyfin.toggleStar
            )
        )
        .onAppear { self.model.attach(self.library.jellyfin.annotations) }
    }
}

// MARK: - Favourites

extension JellyfinSourceModel {
    /// Flips a row's favourite through the shared coordinator. Without a
    /// favourites queue (tests, snapshots) the click does nothing.
    func toggleStar(_ row: JellyfinSongTableRow) {
        self.annotations?.toggleStar(serverID: row.serverID, itemID: row.song.id, currentlyStarred: row.starred)
    }
}

// MARK: - Now playing

extension NowPlayingViewModel {
    /// The Jellyfin song table's row id for the song that is playing, or `nil`
    /// when the current item is not a Jellyfin stream. The table moves its
    /// selection onto that row, as the local library and Subsonic lists do.
    var jellyfinRowID: String? {
        guard let serverID = self.nowPlayingJellyfinServerID,
              let itemID = self.nowPlayingJellyfinItemID else { return nil }
        return JellyfinSongTableRow.id(serverID: serverID, songID: itemID)
    }
}

// MARK: - Server name

/// Keeps a view model's `serverName` equal to the sidebar's name for its server.
/// The model owns the rows, and the sidebar list may load, or be renamed, after
/// the view appears. It observes the Jellyfin model directly, because
/// `LibraryViewModel` does not forward that model's changes.
private struct JellyfinServerNameSync: ViewModifier {
    @ObservedObject var jellyfin: JellyfinSourceModel
    let serverID: UUID
    let apply: (String) -> Void

    private var name: String {
        self.jellyfin.servers.first { $0.id == self.serverID }?.name ?? ""
    }

    func body(content: Content) -> some View {
        content.onChange(of: self.name, initial: true) { _, name in
            self.apply(name)
        }
    }
}

extension View {
    /// See `JellyfinServerNameSync`.
    func jellyfinServerName(
        _ jellyfin: JellyfinSourceModel,
        serverID: UUID,
        apply: @escaping (String) -> Void
    ) -> some View {
        self.modifier(JellyfinServerNameSync(jellyfin: jellyfin, serverID: serverID, apply: apply))
    }
}

// MARK: - JellyfinAlbumCell

/// One album in a grid. A small source pill shows over the artwork when `sourceName` is set.
struct JellyfinAlbumCell: View {
    let album: JellyfinAlbum
    let serverID: UUID
    /// `nil` for single-server browsing, to keep the cell clean.
    let sourceName: String?
    let coverArtProvider: JellyfinCoverArtProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            JellyfinCoverImage(
                provider: self.coverArtProvider,
                serverID: self.serverID,
                itemID: self.album.coverArtID,
                tag: self.album.coverArtTag,
                seed: abs(self.album.id.hashValue),
                pixelSize: Int(Theme.albumGridMinWidth * 2)
            )
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if let name = self.sourceName, !name.isEmpty {
                    SubsonicSourcePill(name: name)
                        .padding(6)
                }
            }

            Text(self.album.title)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            Text(self.album.artistName ?? L10n.string("Various Artists"))
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)

            if let subtitle = self.subtitle {
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [self.album.title, self.album.artistName, self.album.year.map(String.init), self.sourceName]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
    }

    /// The year and the song count, when the server sent them. A missing count is not shown as zero.
    private var subtitle: String? {
        let year = self.album.year.map { String($0) }
        let count = self.album.songCount.map { L10n.string("\($0) songs") }
        let parts = [year, count].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - JellyfinOfflineBannerHost

/// Shows the offline banner above a Jellyfin destination whose server is offline.
/// It observes the Jellyfin model directly, because `LibraryViewModel` does not
/// forward that model's changes, and it owns the "Sign in again" route to Settings.
struct JellyfinOfflineBannerHost: View {
    @ObservedObject var model: JellyfinSourceModel
    let destination: SidebarDestination
    @Environment(\.openSettings) private var openSettings
    @Environment(\.settingsRouter) private var settingsRouter

    var body: some View {
        if let serverID = self.destination.jellyfinServerID,
           let state = self.model.connectionStates[serverID],
           state.isOffline {
            JellyfinOfflineBanner(
                state: state,
                onRetry: { Task { await self.model.retryConnection(serverID: serverID) } },
                onSignInAgain: {
                    self.settingsRouter?.open(.sources, serverID: serverID)
                    self.openSettings()
                }
            )
        }
    }
}

// MARK: - JellyfinOfflineBanner

/// Inline banner above a Jellyfin page when the server is offline.
///
/// It looks like `SubsonicOfflineBanner`, with one difference that matters: a
/// refused token cannot be fixed by pinging again, so for that state the button
/// is "Sign in again" and opens Settings. For any other state it is "Retry now".
struct JellyfinOfflineBanner: View {
    let state: SubsonicSidebarConnectionState
    let onRetry: () -> Void
    let onSignInAgain: () -> Void

    private var needsSignIn: Bool {
        if case .authFailed = self.state {
            return true
        }
        return false
    }

    var body: some View {
        if self.state.isOffline {
            HStack(spacing: 10) {
                Image(systemName: self.iconName)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.headline)
                        .font(Typography.subheadline)
                    Text(self.state.displayLabel)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if self.needsSignIn {
                    Button(L10n.string("Sign in again")) { self.onSignInAgain() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(L10n.string("Sign in to this server again"))
                        .help(L10n.string("Opens Settings so you can sign in to this server again."))
                } else {
                    Button(L10n.string("Retry now")) { self.onRetry() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(L10n.string("Retry connection now"))
                        .help(L10n.string("Re-ping this server immediately, bypassing the backoff timer"))
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .overlay(Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 1), alignment: .bottom)
            .accessibilityElement(children: .contain)
        }
    }

    private var iconName: String {
        switch self.state {
        case .authFailed:
            "lock.trianglebadge.exclamationmark"

        case .serverError:
            "exclamationmark.octagon"

        default:
            "wifi.exclamationmark"
        }
    }

    private var headline: String {
        switch self.state {
        case .authFailed:
            L10n.string("Sign-in no longer accepted")

        case .serverError:
            L10n.string("Server returned an error")

        default:
            L10n.string("Server unreachable")
        }
    }
}

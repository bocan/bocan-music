import Foundation
import Jellyfin
import Observability
import SwiftUI

// MARK: - JellyfinSongTableRow

/// Decorated row for the Jellyfin songs `NSTableView`, the twin of
/// `SubsonicSongTableRow`. There is no rating field: Jellyfin has no rating
/// menu here (ADR-097, D3). The star is the server's favourite flag.
///
/// `serverID` and `serverName` are per row so one table can show rows from more
/// than one server (multi-source search results).
struct JellyfinSongTableRow: Identifiable {
    let song: JellyfinSong
    let serverID: UUID
    let serverName: String

    /// Scoped per server, so two servers that expose the same item id never collide.
    var id: String {
        Self.id(serverID: self.serverID, songID: self.song.id)
    }

    /// Composes the per-server row identifier from its parts.
    static func id(serverID: UUID, songID: String) -> String {
        "\(serverID.uuidString)::\(songID)"
    }

    var title: String {
        self.song.title
    }

    var artist: String {
        self.song.artistName ?? ""
    }

    var album: String {
        self.song.albumTitle ?? ""
    }

    var year: Int {
        self.song.year ?? 0
    }

    var genre: String {
        self.song.genre ?? ""
    }

    /// Whole seconds, or 0 when the server sent no length.
    var duration: Int {
        Int(self.song.durationSeconds ?? 0)
    }

    var trackNumber: Int {
        self.song.trackNumber ?? 0
    }

    var discNumber: Int {
        self.song.discNumber ?? 0
    }

    var bitrate: Int {
        self.song.bitrateKbps ?? 0
    }

    var starred: Bool {
        self.song.isStarred
    }

    /// `true` when every displayed value matches `other`. Every displayed field
    /// derives from `song` and the server pair, so comparing those covers the row.
    func hasSameContent(as other: Self) -> Bool {
        self.song == other.song && self.serverID == other.serverID && self.serverName == other.serverName
    }
}

// MARK: - JellyfinSongListModel

/// A list of songs shown in the Jellyfin song table. It is the base of every
/// view model that owns one: Songs, Starred, a playlist, an album, an artist, a
/// genre and search.
///
/// It owns the decorated `rows` and their `rowsVersion`, as the Subsonic view
/// models do (#455, #475): the O(n) decoration runs once per change of the song
/// list or the server name, not once per re-render, and the table skips its
/// per-row walks while the version holds.
@MainActor
public class JellyfinSongListModel: ObservableObject {
    public let serverID: UUID

    @Published public internal(set) var songs: [JellyfinSong] = [] {
        didSet { self.rebuildRows() }
    }

    @Published private(set) var rows: [JellyfinSongTableRow] = [] {
        didSet { self.rowsVersion &+= 1 }
    }

    /// Moves on every write to `rows` via `didSet`, so no path can forget it.
    private(set) var rowsVersion = 0

    /// Display name of this server, carried on every row. The view sets it from
    /// the sidebar list; a rename rebuilds the rows.
    public var serverName: String {
        didSet {
            guard self.serverName != oldValue else { return }
            self.rebuildRows()
        }
    }

    @Published public internal(set) var isLoading = false
    @Published public var errorMessage: String?

    let log = AppLogger.make(.ui)

    public init(serverID: UUID, serverName: String = "") {
        self.serverID = serverID
        self.serverName = serverName
    }

    /// Shows the user's latest favourite clicks over the server's values.
    private weak var annotations: JellyfinAnnotationCoordinator?

    /// Starts following `coordinator`'s favourite overrides. The song table
    /// calls it when it appears; a second call with the same one does nothing.
    func attach(_ coordinator: JellyfinAnnotationCoordinator?) {
        guard let coordinator, coordinator !== self.annotations else { return }
        self.annotations = coordinator
        coordinator.addObserver(self)
        self.rebuildRows()
    }

    private func rebuildRows() {
        let serverID = self.serverID
        let serverName = self.serverName
        let annotations = self.annotations
        self.rows = self.songs.map { song in
            JellyfinSongTableRow(
                song: annotations?.applying(to: song, serverID: serverID) ?? song,
                serverID: serverID,
                serverName: serverName
            )
        }
    }

    /// The text for a failed load: the error's own description when it has one.
    func message(for error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }
}

extension JellyfinSongListModel: JellyfinAnnotationObserving {
    public func annotationOverridesDidChange() {
        self.rebuildRows()
    }
}

// MARK: - JellyfinCoverImage

/// Async-loaded square cover art for a Jellyfin item, with a deterministic
/// gradient placeholder while the URL resolves or when the item has no image.
///
/// The URL carries the access token, so it comes from `JellyfinCoverArtProvider`
/// (an actor hop) and is never logged or stored; `AsyncImage` then loads it.
struct JellyfinCoverImage: View {
    let provider: JellyfinCoverArtProvider?
    let serverID: UUID
    /// The id of the item that owns the image, not necessarily the item shown.
    let itemID: String?
    /// That item's image tag, so a changed cover does not show stale.
    let tag: String?
    let seed: Int
    let pixelSize: Int

    @State private var resolvedURL: URL?

    var body: some View {
        // The placeholder drives the layout so a non-square image never changes the size.
        GradientPlaceholder(seed: self.seed)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url = self.resolvedURL {
                    AsyncImage(url: url) { phase in
                        if case let .success(image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
            .task(id: self.taskKey) {
                await self.resolve()
            }
    }

    private var taskKey: String {
        "\(self.serverID.uuidString)|\(self.itemID ?? "-")|\(self.tag ?? "-")|\(self.pixelSize)"
    }

    private func resolve() async {
        guard let provider, let itemID else {
            self.resolvedURL = nil
            return
        }
        do {
            self.resolvedURL = try await provider.coverArtURL(
                serverID: self.serverID,
                itemID: itemID,
                tag: self.tag,
                size: self.pixelSize
            )
        } catch {
            // The provider has already logged the failure (without the URL).
            self.resolvedURL = nil
        }
    }
}

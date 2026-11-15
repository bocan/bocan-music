import AppKit
import Foundation

// MARK: - JellyfinSongDragPayload

/// The drag payload for a streamed Jellyfin song. It carries enough to rebuild a
/// `.jellyfin` queue item on drop without asking the server again, as the
/// Subsonic payload does (#332). A drag of several selected rows carries an array.
///
/// Slice 4 writes the payload when a row is dragged out. The drop target for the
/// Up Next queue comes with the `.jellyfin` queue item in slice 5.
public struct JellyfinSongDragPayload: Codable, Sendable, Hashable {
    public let serverID: UUID
    public let songID: String
    public let title: String
    public let artist: String
    public let album: String
    public let genre: String
    /// Track length in whole seconds (0 when unknown).
    public let durationSeconds: Int

    public init(
        serverID: UUID,
        songID: String,
        title: String,
        artist: String,
        album: String,
        genre: String,
        durationSeconds: Int
    ) {
        self.serverID = serverID
        self.songID = songID
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.durationSeconds = durationSeconds
    }
}

/// Pasteboard types used by Bòcan's Jellyfin drag and drop.
public extension NSPasteboard.PasteboardType {
    /// App-private drag type for one or more `JellyfinSongDragPayload`s, JSON-encoded.
    static let bocanJellyfinSong = NSPasteboard.PasteboardType("io.cloudcauldron.bocan.jellyfin-song")
}

/// Encoding and decoding of the Jellyfin song drag payload.
public enum JellyfinSongDrag {
    /// Encodes payloads onto one `NSPasteboardItem` under `.bocanJellyfinSong`.
    /// Returns `nil` for no payloads or an encoding failure (which is logged by the caller's table).
    public static func pasteboardItem(for payloads: [JellyfinSongDragPayload]) -> NSPasteboardItem? {
        guard !payloads.isEmpty else { return nil }
        do {
            let data = try JSONEncoder().encode(payloads)
            let item = NSPasteboardItem()
            item.setData(data, forType: .bocanJellyfinSong)
            return item
        } catch {
            return nil
        }
    }

    /// Reads payloads from pasteboard items. An item that does not decode is skipped.
    public static func payloads(from items: [NSPasteboardItem]) -> [JellyfinSongDragPayload] {
        items.flatMap { item -> [JellyfinSongDragPayload] in
            guard let data = item.data(forType: .bocanJellyfinSong) else { return [] }
            do {
                return try JSONDecoder().decode([JellyfinSongDragPayload].self, from: data)
            } catch {
                return []
            }
        }
    }
}

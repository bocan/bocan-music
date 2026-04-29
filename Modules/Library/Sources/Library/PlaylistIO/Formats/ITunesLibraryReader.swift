import Foundation
import Observability

/// Streaming reader for an iTunes/Music app `Library.xml` plist.
///
/// The file is an Apple plist of:
///   `dict { Tracks: dict<string, dict>, Playlists: array<dict> }`
///
/// Track dicts carry: `Track ID` (Int), `Name`, `Artist`, `Album`,
/// `Total Time` (ms), `Location` (file:// URL).
///
/// Playlist dicts carry: `Name`, `Folder` (Bool), `Parent Persistent ID`,
/// `Persistent ID`, `Smart Info` (Data), and `Playlist Items` — an array of
/// `{ Track ID = N }` dicts.
public enum ITunesLibraryReader {
    public struct Result: Sendable {
        public let tracks: [Int: TrackEntry]
        public let playlists: [PlaylistEntry]
        public init(tracks: [Int: TrackEntry], playlists: [PlaylistEntry]) {
            self.tracks = tracks
            self.playlists = playlists
        }
    }

    public struct TrackEntry: Sendable, Hashable {
        public let id: Int
        public let name: String?
        public let artist: String?
        public let album: String?
        public let durationMs: Int?
        public let locationURL: URL?
        public let playCount: Int
        public let lastPlayedAt: Date?
        public let rating: Int?
        public let loved: Bool

        public init(
            id: Int,
            name: String?,
            artist: String?,
            album: String?,
            durationMs: Int?,
            locationURL: URL?,
            playCount: Int = 0,
            lastPlayedAt: Date? = nil,
            rating: Int? = nil,
            loved: Bool = false
        ) {
            self.id = id
            self.name = name
            self.artist = artist
            self.album = album
            self.durationMs = durationMs
            self.locationURL = locationURL
            self.playCount = playCount
            self.lastPlayedAt = lastPlayedAt
            self.rating = rating
            self.loved = loved
        }
    }

    public struct PlaylistEntry: Sendable, Hashable {
        public let name: String
        public let isFolder: Bool
        public let isSmart: Bool
        public let isMaster: Bool
        public let parentPersistentID: String?
        public let persistentID: String?
        public let trackIDs: [Int]
        public init(
            name: String,
            isFolder: Bool,
            isSmart: Bool,
            isMaster: Bool,
            parentPersistentID: String?,
            persistentID: String?,
            trackIDs: [Int]
        ) {
            self.name = name
            self.isFolder = isFolder
            self.isSmart = isSmart
            self.isMaster = isMaster
            self.parentPersistentID = parentPersistentID
            self.persistentID = persistentID
            self.trackIDs = trackIDs
        }
    }

    public static func parse(url: URL) throws -> Result {
        let data = try Data(contentsOf: url)
        return try self.parse(data: data)
    }

    public static func parse(data: Data) throws -> Result {
        // Use PropertyListSerialization. iTunes Library files can be large
        // (hundreds of MB) but `PropertyListSerialization` is the only
        // accurate way to read Apple plists; XMLParser would require us to
        // re-implement plist semantics. Fall back to a streaming approach
        // only if benchmarks demand it.
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw PlaylistIOError.malformed(format: "iTunes XML", reason: String(describing: error))
        }
        guard let root = plist as? [String: Any] else {
            throw PlaylistIOError.malformed(format: "iTunes XML", reason: "root is not a dictionary")
        }

        let trackDict = (root["Tracks"] as? [String: Any]) ?? [:]
        var tracks: [Int: TrackEntry] = [:]
        tracks.reserveCapacity(trackDict.count)
        for (_, raw) in trackDict {
            guard let row = raw as? [String: Any], let tid = row["Track ID"] as? Int else { continue }
            let locationURL: URL? = {
                guard let s = row["Location"] as? String else { return nil }
                return URL(string: s)
            }()
            tracks[tid] = TrackEntry(
                id: tid,
                name: row["Name"] as? String,
                artist: row["Artist"] as? String,
                album: row["Album"] as? String,
                durationMs: row["Total Time"] as? Int,
                locationURL: locationURL,
                playCount: row["Play Count"] as? Int ?? 0,
                lastPlayedAt: row["Play Date UTC"] as? Date,
                rating: row["Rating"] as? Int,
                loved: row["Loved"] as? Bool ?? false
            )
        }

        let rawPlaylists = (root["Playlists"] as? [[String: Any]]) ?? []
        var playlists: [PlaylistEntry] = []
        playlists.reserveCapacity(rawPlaylists.count)
        for row in rawPlaylists {
            let name = (row["Name"] as? String) ?? "Untitled Playlist"
            let isFolder = (row["Folder"] as? Bool) ?? false
            let isSmart = row["Smart Info"] != nil || row["Smart Criteria"] != nil
            let isMaster = (row["Master"] as? Bool) ?? false
            let parent = row["Parent Persistent ID"] as? String
            let pid = row["Playlist Persistent ID"] as? String
            let items = (row["Playlist Items"] as? [[String: Any]]) ?? []
            let trackIDs = items.compactMap { $0["Track ID"] as? Int }
            playlists.append(PlaylistEntry(
                name: name,
                isFolder: isFolder,
                isSmart: isSmart,
                isMaster: isMaster,
                parentPersistentID: parent,
                persistentID: pid,
                trackIDs: trackIDs
            ))
        }

        AppLogger.make(.library).debug(
            "itunes.parse",
            ["tracks": tracks.count, "playlists": playlists.count]
        )

        return Result(tracks: tracks, playlists: playlists)
    }
}

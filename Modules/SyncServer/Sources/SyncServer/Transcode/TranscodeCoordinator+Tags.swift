import Foundation
import Persistence

// MARK: - Artifact tags

extension TranscodeCoordinator {
    /// The artist and album names the artifact tags are built from, by id.
    struct TagNames {
        let artistName: [Int64: String]
        let albumTitle: [Int64: String]
    }

    static func nameMap(_ pairs: [(Int64?, String)]) -> [Int64: String] {
        var map: [Int64: String] = [:]
        for (id, name) in pairs {
            if let id {
                map[id] = name
            }
        }
        return map
    }

    /// The tags the artifact carries so the file is self-describing off-device.
    static func metadata(
        for track: Track,
        artistName: [Int64: String],
        albumTitle: [Int64: String]
    ) -> [String: String] {
        var tags: [String: String] = [:]
        if let title = track.title {
            tags["title"] = title
        }
        if let artistID = track.artistID, let name = artistName[artistID] {
            tags["artist"] = name
        }
        if let albumArtistID = track.albumArtistID, let name = artistName[albumArtistID] {
            tags["album_artist"] = name
        }
        if let albumID = track.albumID, let title = albumTitle[albumID] {
            tags["album"] = title
        }
        if let trackNumber = track.trackNumber {
            tags["track"] = "\(trackNumber)"
        }
        if let discNumber = track.discNumber {
            tags["disc"] = "\(discNumber)"
        }
        if let year = track.year {
            tags["date"] = "\(year)"
        }
        if let genre = track.genre {
            tags["genre"] = genre
        }
        return tags
    }
}

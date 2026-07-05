/// MusicBrainz recording response from
/// `GET /ws/2/recording/<mbid>?inc=releases+release-groups+artists+tags+isrcs+media&fmt=json`.
///
/// Every field beyond `id`/`title` is optional: MusicBrainz omits keys freely, and a
/// niche release must never fail the whole decode.
public struct MBRecording: Decodable, Sendable {
    public let id: String
    public let title: String
    /// Duration in milliseconds.
    public let length: Int?
    public let artistCredit: [MBArtistCredit]?
    public let releases: [MBRelease]?
    public let tags: [MBTag]?
    /// ISRCs registered for this recording (usually 0 or 1; remasters can carry several).
    public let isrcs: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, length, releases, tags, isrcs
        case artistCredit = "artist-credit"
    }

    /// Primary artist display name built from credit list.
    public var artistName: String {
        self.artistCredit?.map { credit in
            (credit.name ?? credit.artist?.name ?? "") + (credit.joinphrase ?? "")
        }.joined() ?? ""
    }

    /// Most prominent genre tag by vote count, if any.  Title-cased since MB tags are lowercase.
    public var topGenre: String? {
        self.tags?.max(by: { $0.count < $1.count })?.name.titleCased
    }
}

public struct MBArtistCredit: Decodable, Sendable {
    public let name: String?
    public let joinphrase: String?
    public let artist: MBArtist?
}

public struct MBArtist: Decodable, Sendable {
    public let id: String
    public let name: String
}

public struct MBRelease: Decodable, Sendable {
    public let id: String
    public let title: String
    /// ISO 8601 partial date string, e.g. "1969-09-26" or "1969".
    public let date: String?
    public let status: String?
    /// ISO 3166 country code, e.g. "GB".
    public let country: String?
    public let artistCredit: [MBArtistCredit]?
    /// Only populated by *release* endpoint lookups (`inc=labels`). The recording
    /// endpoint rejects `labels` as an inc parameter, so identification candidates
    /// never carry label data today; the field is kept for a future per-release fetch.
    public let labelInfo: [MBLabelInfo]?
    public let media: [MBMedium]?
    public let releaseGroup: MBReleaseGroup?

    enum CodingKeys: String, CodingKey {
        case id, title, date, status, country, media
        case artistCredit = "artist-credit"
        case labelInfo = "label-info"
        case releaseGroup = "release-group"
    }

    public var year: Int? {
        guard let d = self.date, d.count >= 4 else { return nil }
        return Int(d.prefix(4))
    }

    public var albumArtistName: String? {
        guard let credits = self.artistCredit, !credits.isEmpty else { return nil }
        let name = credits.map { credit in
            (credit.name ?? credit.artist?.name ?? "") + (credit.joinphrase ?? "")
        }.joined()
        return name.isEmpty ? nil : name
    }
}

public struct MBLabelInfo: Decodable, Sendable {
    public let label: MBLabel?
    public let catalogNumber: String?

    enum CodingKeys: String, CodingKey {
        case label
        case catalogNumber = "catalog-number"
    }
}

public struct MBLabel: Decodable, Sendable {
    public let id: String?
    public let name: String
}

public struct MBMedium: Decodable, Sendable {
    public let position: Int?
    /// Full track count of the medium. In recording lookups `tracks` is only the
    /// subset containing the looked-up recording, but this count stays complete.
    public let trackCount: Int?
    /// "CD", "12\" Vinyl", "Cassette", "Digital Media", …
    public let format: String?
    public let tracks: [MBTrack]?

    enum CodingKeys: String, CodingKey {
        case position, format, tracks
        case trackCount = "track-count"
    }
}

/// Release-group summary attached to each release (`inc=release-groups`).
public struct MBReleaseGroup: Decodable, Sendable {
    public let id: String
    /// "Album", "Single", "EP", …
    public let primaryType: String?
    /// e.g. ["Compilation"], ["Live"], ["Soundtrack"] — empty/absent for straight albums.
    public let secondaryTypes: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case primaryType = "primary-type"
        case secondaryTypes = "secondary-types"
    }
}

public struct MBTrack: Decodable, Sendable {
    /// Track number as a string (may be "A1", "B2", etc. for vinyl).
    public let number: String?
    public let position: Int?
    public let title: String?

    public var trackNumber: Int? {
        self.position ?? self.number.flatMap(Int.init)
    }
}

public struct MBTag: Decodable, Sendable {
    public let name: String
    public let count: Int
}

// MARK: - Helpers

private extension String {
    var titleCased: String {
        self.capitalized(with: .current)
    }
}

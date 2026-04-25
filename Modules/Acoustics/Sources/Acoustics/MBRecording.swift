/// MusicBrainz recording response from `GET /ws/2/recording/<mbid>?inc=releases+artists+tags&fmt=json`.
public struct MBRecording: Decodable, Sendable {
    public let id: String
    public let title: String
    /// Duration in milliseconds.
    public let length: Int?
    public let artistCredit: [MBArtistCredit]?
    public let releases: [MBRelease]?
    public let tags: [MBTag]?

    enum CodingKeys: String, CodingKey {
        case id, title, length, releases, tags
        case artistCredit = "artist-credit"
    }

    /// Primary artist display name built from credit list.
    public var artistName: String {
        self.artistCredit?.map { credit in
            (credit.name ?? credit.artist?.name ?? "") + (credit.joinphrase ?? "")
        }.joined() ?? ""
    }

    /// Most prominent genre tag by vote count, if any.
    public var topGenre: String? {
        self.tags?.max(by: { $0.count < $1.count })?.name
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
    public let artistCredit: [MBArtistCredit]?
    public let labelInfo: [MBLabelInfo]?
    public let media: [MBMedium]?

    enum CodingKeys: String, CodingKey {
        case id, title, date, status, media
        case artistCredit = "artist-credit"
        case labelInfo = "label-info"
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
    public let trackCount: Int?
    public let tracks: [MBTrack]?

    enum CodingKeys: String, CodingKey {
        case position, tracks
        case trackCount = "track-count"
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

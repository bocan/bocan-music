import Foundation

// MARK: - Artist lookup (`GET /ws/2/artist/<mbid>?inc=url-rels+artist-rels+aliases`)

/// An artist with relations, for Deep Dive (#413). Every field beyond
/// `id`/`name` is optional: MusicBrainz omits keys freely.
public struct MBArtistDetail: Decodable, Sendable {
    public let id: String
    public let name: String
    public let sortName: String?
    public let disambiguation: String?
    /// "Person", "Group", "Orchestra", "Choir", "Character", "Other".
    public let type: String?
    /// ISO 3166 country code, e.g. "GB".
    public let country: String?
    public let lifeSpan: MBLifeSpan?
    public let relations: [MBRelation]?

    enum CodingKeys: String, CodingKey {
        case id, name, disambiguation, type, country, relations
        case sortName = "sort-name"
        case lifeSpan = "life-span"
    }

    /// Band members ("member of band" relations pointing at this group),
    /// current members first, then by join date.
    public var members: [MBMembership] {
        (self.relations ?? [])
            .filter { $0.type == "member of band" && $0.direction == "backward" }
            .compactMap { rel in
                rel.artist.map {
                    MBMembership(artist: $0, begin: rel.begin, end: rel.end, ended: rel.ended ?? false, attributes: rel.attributes ?? [])
                }
            }
            .sorted { lhs, rhs in
                if lhs.ended != rhs.ended { return !lhs.ended }
                return (lhs.begin ?? "") < (rhs.begin ?? "")
            }
    }

    /// External links keyed by relation type ("wikidata", "discogs", "official homepage", ...).
    public var links: [String: URL] {
        var out: [String: URL] = [:]
        for rel in self.relations ?? [] {
            if let resource = rel.url?.resource, let url = URL(string: resource), out[rel.type] == nil {
                out[rel.type] = url
            }
        }
        return out
    }

    /// The Wikidata item id (e.g. "Q1299") from the `wikidata` URL relation.
    public var wikidataID: String? {
        self.links["wikidata"]?.lastPathComponent
    }
}

public struct MBLifeSpan: Decodable, Sendable {
    public let begin: String?
    public let end: String?
    public let ended: Bool?
}

public struct MBRelation: Decodable, Sendable {
    public let type: String
    public let direction: String?
    public let begin: String?
    public let end: String?
    public let ended: Bool?
    public let attributes: [String]?
    public let artist: MBArtist?
    public let url: MBRelationURL?
}

public struct MBRelationURL: Decodable, Sendable {
    public let id: String?
    public let resource: String
}

/// A band membership derived from an artist's relations.
public struct MBMembership: Sendable, Equatable {
    public let artist: MBArtist
    public let begin: String?
    public let end: String?
    public let ended: Bool
    /// Instruments / roles, e.g. ["guitar", "lead vocals"].
    public let attributes: [String]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artist.id == rhs.artist.id && lhs.begin == rhs.begin && lhs.end == rhs.end
    }
}

// MARK: - Artist search (`GET /ws/2/artist?query=...`)

public struct MBArtistSearchResponse: Decodable, Sendable {
    public let artists: [MBArtistSearchResult]
}

public struct MBArtistSearchResult: Decodable, Sendable {
    public let id: String
    public let name: String
    public let sortName: String?
    public let disambiguation: String?
    public let type: String?
    public let country: String?
    /// Lucene relevance, 0-100.
    public let score: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, disambiguation, type, country, score
        case sortName = "sort-name"
    }
}

// MARK: - Release-group search and browse

public struct MBReleaseGroupSearchResponse: Decodable, Sendable {
    public let releaseGroups: [MBReleaseGroup]

    enum CodingKeys: String, CodingKey {
        case releaseGroups = "release-groups"
    }
}

public struct MBReleaseGroupBrowse: Decodable, Sendable {
    public let releaseGroupCount: Int?
    public let releaseGroupOffset: Int?
    public let releaseGroups: [MBReleaseGroup]

    enum CodingKeys: String, CodingKey {
        case releaseGroupCount = "release-group-count"
        case releaseGroupOffset = "release-group-offset"
        case releaseGroups = "release-groups"
    }
}

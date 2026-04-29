import Foundation

/// How playlist writers should render entry paths.
public enum PathMode: Sendable, Equatable {
    /// Always write absolute filesystem paths.
    case absolute
    /// Write relative paths when the entry sits under `root`; fall back to
    /// absolute on a per-row basis when it does not.
    case relative(to: URL)
}

/// Hint used when a playlist entry could not be resolved to a library track.
/// Used to populate the "review unresolved" UI and to seed fuzzy matching.
public struct TrackHint: Sendable, Hashable {
    public let path: String
    public let absoluteURL: URL?
    public let title: String?
    public let artist: String?
    public let album: String?
    public let durationHint: TimeInterval?

    public init(
        path: String,
        absoluteURL: URL? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        durationHint: TimeInterval? = nil
    ) {
        self.path = path
        self.absoluteURL = absoluteURL
        self.title = title
        self.artist = artist
        self.album = album
        self.durationHint = durationHint
    }
}

/// A playlist plus its entries, format-agnostic.
public struct PlaylistPayload: Sendable, Hashable {
    public let name: String
    public let entries: [Entry]

    public struct Entry: Sendable, Hashable {
        public let path: String
        public let absoluteURL: URL?
        public let durationHint: TimeInterval?
        public let titleHint: String?
        public let artistHint: String?
        public let albumHint: String?

        public init(
            path: String,
            absoluteURL: URL? = nil,
            durationHint: TimeInterval? = nil,
            titleHint: String? = nil,
            artistHint: String? = nil,
            albumHint: String? = nil
        ) {
            self.path = path
            self.absoluteURL = absoluteURL
            self.durationHint = durationHint
            self.titleHint = titleHint
            self.artistHint = artistHint
            self.albumHint = albumHint
        }

        /// Convert to a `TrackHint` for the resolver/UI.
        public var hint: TrackHint {
            TrackHint(
                path: self.path,
                absoluteURL: self.absoluteURL,
                title: self.titleHint,
                artist: self.artistHint,
                album: self.albumHint,
                durationHint: self.durationHint
            )
        }
    }

    public init(name: String, entries: [Entry]) {
        self.name = name
        self.entries = entries
    }
}

/// Outcome of resolving a `PlaylistPayload` against the library.
public struct Resolution: Sendable, Hashable {
    public struct Match: Sendable, Hashable {
        public let entryIndex: Int
        public let trackID: Int64
        public init(entryIndex: Int, trackID: Int64) {
            self.entryIndex = entryIndex
            self.trackID = trackID
        }
    }

    public struct Miss: Sendable, Hashable {
        public let entryIndex: Int
        public let hint: TrackHint
        public init(entryIndex: Int, hint: TrackHint) {
            self.entryIndex = entryIndex
            self.hint = hint
        }
    }

    public let matches: [Match]
    public let misses: [Miss]

    public init(matches: [Match], misses: [Miss]) {
        self.matches = matches
        self.misses = misses
    }
}

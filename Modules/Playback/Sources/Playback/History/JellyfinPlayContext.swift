import Foundation

// MARK: - JellyfinPlayContext

/// What the scrobble pipeline needs from a Jellyfin play (ADR-097 slice 6). The
/// twin of `SubsonicPlayContext`: a Jellyfin song has no `tracks` row, so the
/// queue item's snapshot travels with the play.
public struct JellyfinPlayContext: Sendable, Equatable {
    public let serverID: UUID
    /// The Jellyfin item id. Opaque: never parsed or re-cased.
    public let itemID: String
    public let title: String
    public let artist: String
    public let albumArtist: String?
    public let album: String?
    /// Track length in seconds; 0 when the server sent none.
    public let duration: TimeInterval

    // Memberwise initialiser: the parameters keep the stored-property order.
    // swiftlint:disable function_default_parameter_at_end
    public init(
        serverID: UUID,
        itemID: String,
        title: String,
        artist: String,
        albumArtist: String? = nil,
        album: String? = nil,
        duration: TimeInterval
    ) {
        self.serverID = serverID
        self.itemID = itemID
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.duration = duration
    }
    // swiftlint:enable function_default_parameter_at_end
}

// MARK: - ScrobbleSink defaults

/// No-op defaults for the Jellyfin `ScrobbleSink` requirements, so a sink that
/// predates ADR-097 still compiles and simply drops Jellyfin plays.
public extension ScrobbleSink {
    /// Default: does nothing, so the Jellyfin play is dropped.
    func recordJellyfinPlay(
        context _: JellyfinPlayContext,
        playedAt _: Date,
        durationPlayed _: TimeInterval
    ) async {}

    /// Default: does nothing.
    func nowPlayingJellyfin(context _: JellyfinPlayContext) async {}
}

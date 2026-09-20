import Foundation

// MARK: - SubsonicBrowseError

/// Failures that originate in the UI-side Subsonic browse layer, as opposed to
/// `SubsonicError`, which the `Subsonic` module throws for transport, keychain
/// and API failures. Neither case reaches the user as text: a timed-out server
/// is listed by name in the search chrome, and the placeholder data source only
/// backs previews and snapshots.
enum SubsonicBrowseError: Error, Sendable {
    /// A browse view was built without a real data source
    /// (`NoopBrowseDataSource`), so there is no server to ask.
    case dataSourceUnavailable

    /// One server did not answer a multi-source search within the per-server
    /// deadline. The other servers' results still show.
    case searchTimedOut(serverID: UUID, after: Duration)
}

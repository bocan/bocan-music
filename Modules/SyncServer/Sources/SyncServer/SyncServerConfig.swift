import Foundation

/// Tunables for the Phone Sync server. The listener always binds an ephemeral
/// port and advertises `_bocansync._tcp`; these are the knobs worth varying
/// (mainly so tests can shorten the change-debounce window).
public struct SyncServerConfig: Sendable {
    /// How long a burst of library edits is coalesced before the `sync_meta`
    /// generation counter bumps (the phone polls the counter to decide to re-sync).
    public var changeDebounce: Duration

    /// The prepare-and-release window (ADR-088): the most un-served artifact
    /// bytes the transcode coordinator holds on disk before pausing.
    public var prepareWindowBytes: Int64

    public init(changeDebounce: Duration = .seconds(5), prepareWindowBytes: Int64 = 5 << 30) {
        self.changeDebounce = changeDebounce
        self.prepareWindowBytes = prepareWindowBytes
    }

    public static let `default` = SyncServerConfig()
}

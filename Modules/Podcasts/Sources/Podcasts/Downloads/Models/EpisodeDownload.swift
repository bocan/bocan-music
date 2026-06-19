import Foundation
import Persistence

/// A snapshot of one episode download's progress, emitted on
/// `EpisodeDownloadManager.progress` for the UI list.
///
/// `status` reuses the persisted `EpisodeDownloadState` vocabulary
/// (`none` / `queued` / `downloading` / `downloaded` / `failed`) so the UI badge
/// and the live indicator speak the same language.
public struct EpisodeDownload: Sendable, Equatable, Identifiable {
    public var podcastID: Int64
    public var guid: String
    public var fractionComplete: Double
    public var bytesWritten: Int64
    public var totalBytes: Int64
    public var status: EpisodeDownloadState

    /// Stable identity for SwiftUI lists: `"<podcastID>/<guid>"`.
    public var id: String {
        "\(self.podcastID)/\(self.guid)"
    }

    public init(
        podcastID: Int64,
        guid: String,
        fractionComplete: Double,
        bytesWritten: Int64,
        totalBytes: Int64,
        status: EpisodeDownloadState
    ) {
        self.podcastID = podcastID
        self.guid = guid
        self.fractionComplete = fractionComplete
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.status = status
    }
}

import CryptoKit
import Foundation
import Observability

/// On-disk layout and path helpers for downloaded podcast episodes.
///
/// Downloads are **user data** the user expects to persist (a downloaded-for-a
/// flight episode), so they live in **Application Support**, not Caches, which
/// macOS may purge under disk pressure. The budget eviction in
/// `EpisodeDownloadManager` is the app's own, deliberate cleanup policy.
///
/// Layout:
/// `<appSupport>/io.cloudcauldron.bocan/Podcasts/Downloads/<podcastID>/<guidHash>.<ext>`
///
/// Guids are arbitrary strings (often URLs with slashes), so the filename is a
/// stable truncated SHA-256 of the guid, never the raw guid.
public struct DownloadStore: Sendable {
    private let root: URL
    private let log = AppLogger.make(.podcasts)

    /// - Parameter root: override the storage root (tests pass a temp directory).
    ///   `nil` uses the default Application Support location.
    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
    }

    private static let defaultRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("io.cloudcauldron.bocan", isDirectory: true)
            .appendingPathComponent("Podcasts", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }()

    // MARK: - Path helpers

    /// The final on-disk URL for an episode's downloaded enclosure. Deterministic:
    /// the same `(podcastID, guid, mime)` always maps to the same path.
    public func fileURL(podcastID: Int64, guid: String, mime: String?) -> URL {
        let ext = Self.fileExtension(forMIME: mime)
        return self.root
            .appendingPathComponent("\(podcastID)", isDirectory: true)
            .appendingPathComponent("\(Self.hash(guid)).\(ext)")
    }

    /// `true` when the episode's downloaded file is present on disk.
    public func exists(podcastID: Int64, guid: String, mime: String?) -> Bool {
        FileManager.default.fileExists(
            atPath: self.fileURL(podcastID: podcastID, guid: guid, mime: mime).path
        )
    }

    /// The size in bytes of the episode's downloaded file, or `nil` if absent.
    public func bytes(podcastID: Int64, guid: String, mime: String?) -> Int64? {
        Self.fileSize(at: self.fileURL(podcastID: podcastID, guid: guid, mime: mime))
    }

    // MARK: - Mutations

    /// Moves a freshly downloaded temp file into its final location, creating the
    /// show directory and replacing any stale file. Returns the final URL.
    ///
    /// Both URLs are on the same volume (the temp file comes from the same
    /// download session), so the move is effectively atomic.
    @discardableResult
    public func moveIntoPlace(
        from tempURL: URL,
        podcastID: Int64,
        guid: String,
        mime: String?
    ) throws -> URL {
        let dest = self.fileURL(podcastID: podcastID, guid: guid, mime: mime)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: tempURL, to: dest)
        self.log.debug("download.store.moved", ["podcastID": podcastID, "path": dest.path])
        return dest
    }

    /// Deletes the episode's downloaded file, if present. No-op when absent.
    public func delete(podcastID: Int64, guid: String, mime: String?) {
        self.removeIfPresent(self.fileURL(podcastID: podcastID, guid: guid, mime: mime))
    }

    /// Deletes a downloaded file by its stored absolute path. Used when the state
    /// row already records the exact path (eviction, `removeDownload`).
    public func deleteFile(atPath path: String) {
        self.removeIfPresent(URL(fileURLWithPath: path))
    }

    /// Removes a show's entire download directory. Called by `unsubscribe`.
    public func deletePodcast(podcastID: Int64) {
        self.removeIfPresent(self.root.appendingPathComponent("\(podcastID)", isDirectory: true))
    }

    /// Removes the whole downloads root. Called by `clearAll`.
    public func deleteAll() {
        self.removeIfPresent(self.root)
    }

    // MARK: - Private

    private func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            self.log.warning(
                "download.store.deleteFailed",
                ["path": url.path, "error": String(reflecting: error)]
            )
        }
    }

    private static func hash(_ guid: String) -> String {
        let digest = SHA256.hash(data: Data(guid.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// Maps an enclosure MIME type to a file extension. Defaults to `mp3` when the
    /// MIME is missing or unrecognised (per the phase 21-6 contract).
    static func fileExtension(forMIME mime: String?) -> String {
        guard let mime else { return "mp3" }
        let key = mime.lowercased().split(separator: ";").first.map(String.init) ?? mime.lowercased()
        return self.mimeExtensions[key.trimmingCharacters(in: .whitespaces)] ?? "mp3"
    }

    private static let mimeExtensions: [String: String] = [
        "audio/mpeg": "mp3",
        "audio/mp3": "mp3",
        "audio/mp4": "m4a",
        "audio/x-m4a": "m4a",
        "audio/aac": "aac",
        "audio/ogg": "ogg",
        "audio/opus": "opus",
        "audio/wav": "wav",
        "audio/x-wav": "wav",
        "audio/flac": "flac",
    ]

    private static func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }
}

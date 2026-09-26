import Foundation
import Testing

/// Source convention (#569): only the owners of rebuildable cache folders call
/// `CacheDirectoryMarker.mark`. The library database, `CoverArt/`,
/// `EditBackups/`, `Backups/`, podcast downloads and playlist covers cannot be
/// rebuilt, so a backup tool must never skip them. A new call site fails this
/// test until it is added below on purpose.
@Suite("CacheDirectoryMarker call sites")
struct CacheDirectoryMarkerConventionTests {
    /// Repo-relative files allowed to mark a folder, with the folder each marks.
    private static let owners: Set = [
        "App/BocanApp.swift", // ~/Library/Caches/io.cloudcauldron.bocan (tag only)
        "Modules/SyncServer/Sources/SyncServer/Transcode/TranscodeStore.swift", // SyncTranscodes
        "Modules/Library/Sources/Library/CoverArt/CoverArtSearchService.swift", // Bocan/CoverArtCache
        "Modules/Library/Sources/Library/DeepDive/DeepDiveCache.swift", // Bocan/DeepDive
        "Modules/Podcasts/Sources/Podcasts/PodcastArtworkCache.swift", // Podcasts/Artwork
    ]

    /// Owners of folders that must never be marked, so a match here is named
    /// in the failure even if someone also adds it to `owners`.
    private static let neverMark: Set = [
        "Modules/Library/Sources/Library/CoverArtCache.swift", // CoverArt/
        "Modules/Library/Sources/Library/Edit/MetadataEditService.swift", // EditBackups/
        "Modules/Persistence/Sources/Persistence/Backup/BackupService.swift", // Backups/
        "Modules/Podcasts/Sources/Podcasts/Downloads/DownloadStore.swift", // Podcasts/Downloads/
        "Modules/UI/Sources/UI/Playlists/ViewModels/PlaylistSidebarViewModel+CoverArt.swift", // playlist_covers/
    ]

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ObservabilityTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Observability
        .deletingLastPathComponent() // Modules
        .deletingLastPathComponent()

    private static func swiftFiles(under relative: String) -> [String] {
        let base = Self.repoRoot.appendingPathComponent(relative, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/.build/") && !$0.path.contains("/Tests/") }
            .map { String($0.path.dropFirst(Self.repoRoot.path.count + 1)) }
    }

    @Test("only the five cache owners mark a folder")
    func onlyCacheOwnersMark() throws {
        let sources = Self.swiftFiles(under: "App") + Self.swiftFiles(under: "Modules")
        #expect(!sources.isEmpty, "the scan found no sources; the repo root is wrong")
        var callers: Set<String> = []
        for file in sources {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(file), encoding: .utf8)
            if text.contains("CacheDirectoryMarker.mark(") {
                callers.insert(file)
            }
        }
        #expect(callers == Self.owners)
        #expect(callers.isDisjoint(with: Self.neverMark))
    }
}

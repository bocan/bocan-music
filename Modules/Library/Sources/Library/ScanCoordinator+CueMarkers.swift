import Foundation
import Persistence

// MARK: - CUE marker pass

extension ScanCoordinator {
    /// ADR-087: attach sidecar CUE sheets as in-track markers once the
    /// audio is indexed. Cue files are not walker entries (the walker is
    /// audio-only); this is a cheap per-folder pass, and a folder with no
    /// cues costs one directory listing.
    func attachCueMarkers(roots: [(url: URL, rootID: Int64)]) async {
        guard !Task.isCancelled else { return }
        let markerService = CueMarkerService(
            trackRepo: self.trackRepo,
            markerRepo: TrackMarkerRepository(database: self.database)
        )
        var cueFolders: Set<URL> = []
        for root in roots {
            cueFolders.formUnion(Self.cueFolders(under: root.url))
        }
        for folder in cueFolders where !Task.isCancelled {
            await markerService.attachMarkers(inFolder: folder)
        }
    }

    /// The distinct folders under `root` that contain `.cue` files, hidden
    /// paths skipped (ADR-087's per-folder marker pass).
    static func cueFolders(under root: URL) -> Set<URL> {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var folders: Set<URL> = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "cue" {
            folders.insert(url.deletingLastPathComponent())
        }
        return folders
    }
}

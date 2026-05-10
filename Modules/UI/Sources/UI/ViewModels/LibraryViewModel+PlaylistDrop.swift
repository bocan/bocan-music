import Foundation
import Observability

// MARK: - LibraryViewModel + Playlist drop-import

/// Playlist-file import logic triggered by drag-and-drop.
///
/// Separated from `LibraryViewModel+Scanning.swift` to keep each extension
/// file under the 500-line lint limit.
extension LibraryViewModel {
    /// Imports one or more dropped playlist files via ``PlaylistImportService``.
    ///
    /// A single file is imported directly with no folder wrapper. Multiple files
    /// are grouped inside a new dated folder so the sidebar stays tidy.
    func importDroppedPlaylists(_ urls: [URL]) async {
        // For multi-file drops, create a containing folder first.
        var parentID: Int64?
        if urls.count > 1 {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let folderName = "Dropped Playlists \u{2013} \(formatter.string(from: Date()))"
            do {
                let folder = try await self.playlistService.createFolder(name: folderName)
                parentID = folder.id
                self.log.debug("playlist.drop.folder.created", ["name": folderName])
            } catch {
                self.log.error("playlist.drop.createFolder.failed", ["error": String(reflecting: error)])
            }
        }

        for url in urls {
            do {
                let start = Date()
                let report = try await self.playlistImporter.importFile(at: url, parentID: parentID)
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                self.log.debug("playlist.drop.imported", [
                    "name": report.payloadName,
                    "playlist_id": report.playlistID,
                    "elapsed_ms": elapsed,
                ])
            } catch {
                self.log.error("playlist.drop.import.failed", [
                    "file": url.lastPathComponent,
                    "error": String(reflecting: error),
                ])
            }
        }

        await self.playlistSidebar.reload()
    }
}

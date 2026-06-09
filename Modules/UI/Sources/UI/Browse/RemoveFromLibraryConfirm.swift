import AppKit
import Foundation

// MARK: - RemoveFromLibraryConfirm

/// Shared "Remove from Library" (soft-delete) confirmation for the album and
/// artist context-menu actions. Mirrors the per-track confirmation in
/// `TracksView+Actions` and reuses its alert presenter and "Don't ask again"
/// suppression key, so the preference is unified across track, album, and
/// artist removal (issue #258).
@MainActor
enum RemoveFromLibraryConfirm {
    /// Confirms removing one or more albums, then performs the soft-delete.
    /// `soleTitle` names the album in the prompt when removing exactly one.
    static func albums(ids: [Int64], soleTitle: String?, library: LibraryViewModel) async {
        guard !ids.isEmpty else { return }
        await self.present(messageText: self.albumsMessage(count: ids.count, soleTitle: soleTitle)) {
            await library.removeAlbumsFromLibrary(albumIDs: ids)
        }
    }

    /// Confirms removing all music by an artist, then performs the soft-delete.
    static func artist(id: Int64, name: String?, library: LibraryViewModel) async {
        await self.present(messageText: self.artistMessage(name: name)) {
            await library.removeArtistFromLibrary(artistID: id)
        }
    }

    // MARK: - Message text (pure, testable)

    /// Confirmation title for removing `count` albums. Names the album when
    /// removing exactly one and its title is known.
    nonisolated static func albumsMessage(count: Int, soleTitle: String?) -> String {
        if count <= 1, let title = soleTitle, !title.isEmpty {
            return L10n.string("Remove “\(title)” from library?")
        }
        return L10n.string("Remove \(count) albums from library?")
    }

    /// Confirmation title for removing all music by an artist.
    nonisolated static func artistMessage(name: String?) -> String {
        if let name, !name.isEmpty {
            return L10n.string("Remove all music by “\(name)” from library?")
        }
        return L10n.string("Remove this artist from library?")
    }

    // MARK: - Presentation

    /// Presents the shared soft-delete alert and runs `perform` on confirm (or
    /// immediately when the user previously chose "Don't ask again").
    private static func present(messageText: String, perform: () async -> Void) async {
        if UserDefaults.standard.bool(forKey: TracksView.suppressRemoveKey) {
            await perform()
            return
        }

        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = L10n.string(
            "The files will stay on disk and can be re-added later by rescanning the folder."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Remove"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.string("Don’t ask again")

        guard await TracksView.runAlertAsync(alert) == .alertFirstButtonReturn else { return }

        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: TracksView.suppressRemoveKey)
        }
        await perform()
    }
}

import AppKit
import Library
import Observability

// MARK: - OriginalCoverOpener

/// "Show Original Cover": opens an album's cover at full size in the default
/// image viewer. The cache keeps covers at no more than 4096 px and the
/// original of a larger one beside them (#583); `CoverArtFiles` picks
/// whichever is the full image. Shared by the album page and the Albums grid.
@MainActor
enum OriginalCoverOpener {
    /// Opens the full-size cover for the working art at `workingPath`. A
    /// missing file or a failed open is logged and shown as a toast.
    static func open(workingPath: String?, albumID: Int64?, library: LibraryViewModel) {
        let log = AppLogger.make(.ui)
        guard let workingPath, let url = CoverArtFiles.fullSizeURL(forWorkingPath: workingPath) else {
            log.warning("album.showOriginal.missing", ["albumID": albumID ?? -1])
            library.showToast(ToastMessage(text: L10n.string("The cover image is no longer on disk.")))
            return
        }
        if !NSWorkspace.shared.open(url) {
            log.warning("album.showOriginal.openFailed", ["path": url.path])
            library.showToast(ToastMessage(text: L10n.string("Couldn’t open the cover image.")))
        }
    }
}

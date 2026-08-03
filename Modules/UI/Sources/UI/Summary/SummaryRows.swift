import AppKit
import Persistence
import SwiftUI

// MARK: - SummaryOffenderRow

/// A Library Summary offender row shared by the report panes. With an
/// `albumID` it becomes a button that jumps the main window to that album
/// and brings it forward (the summary window stays open as the user's
/// worklist); with a `trackID` too, the exact song is selected and scrolled
/// into view. Without an album it renders as plain text.
struct SummaryOffenderRow: View {
    let title: String
    let detail: String
    let albumID: Int64?
    /// Held as a plain `let`: only used to navigate, never observed.
    let library: LibraryViewModel
    let trackID: Int64?

    init(
        title: String,
        detail: String,
        albumID: Int64?,
        library: LibraryViewModel,
        trackID: Int64? = nil
    ) {
        self.title = title
        self.detail = detail
        self.albumID = albumID
        self.library = library
        self.trackID = trackID
    }

    var body: some View {
        if let albumID {
            Button {
                self.openAlbum(albumID)
            } label: {
                HStack(spacing: 6) {
                    self.rowText
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(self.trackID == nil
                ? L10n.string("Double-tap to open album")
                : L10n.string("Double-tap to open the album and select this song"))
        } else {
            self.rowText
        }
    }

    private var rowText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.title)
                .font(Typography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Text(self.detail)
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
    }

    private func openAlbum(_ albumID: Int64) {
        if let trackID = self.trackID {
            Task { await self.library.revealTrack(trackID, inAlbum: albumID) }
        } else {
            Task { await self.library.selectDestination(.album(albumID)) }
        }
        MainWindowTracker.shared.resolveWindow()?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - SummaryMoreRow

/// The "and N more" trailer under a capped offender list.
struct SummaryMoreRow: View {
    let total: Int
    let shown: Int

    var body: some View {
        if self.total > self.shown {
            Text(localized: "and \(self.total - self.shown) more")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }
}

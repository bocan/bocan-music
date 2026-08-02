import AppKit
import Persistence
import SwiftUI

// MARK: - SummaryOffenderRow

/// A Library Summary offender row shared by the hygiene and audio-quality
/// panes. With an `albumID` it becomes a button that jumps the main window
/// to that album and brings it forward (the summary window stays open as the
/// user's worklist); without one it renders as plain text.
struct SummaryOffenderRow: View {
    let title: String
    let detail: String
    let albumID: Int64?
    /// Held as a plain `let`: only used to navigate, never observed.
    let library: LibraryViewModel

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
            .accessibilityHint(L10n.string("Double-tap to open album"))
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
        Task { await self.library.selectDestination(.album(albumID)) }
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

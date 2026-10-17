import AppKit
import SwiftUI

// MARK: - PodcastShowRow

/// A Library Summary row that jumps the main window to a podcast show, or to
/// that show's downloads, and brings it forward, mirroring
/// `SummaryOffenderRow`'s album navigation. Split out of
/// `LibraryPodcastsPane.swift` for file_length headroom.
struct PodcastShowRow: View {
    let title: String
    let detail: String
    let podcastID: Int64
    /// Held as a plain `let`: only used to navigate, never observed.
    let library: LibraryViewModel
    /// Opens the Downloaded list kept to this show, not the show page, where old
    /// downloads sit far down a newest-first list, out of sight (#654).
    var opensDownloads = false

    var body: some View {
        Button {
            Task {
                if self.opensDownloads {
                    self.library.podcasts.downloadedShowFilter = self.podcastID
                    await self.library.selectDestination(.podcastDownloads)
                } else {
                    await self.library.selectDestination(.podcastShow(self.podcastID))
                }
            }
            MainWindowTracker.shared.resolveWindow()?.makeKeyAndOrderFront(nil)
        } label: {
            HStack(spacing: 6) {
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
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(self.hint)
        .help(self.helpText)
    }

    private var hint: String {
        self.opensDownloads
            ? L10n.string("Double-tap to open this show's downloads")
            : L10n.string("Double-tap to open the show")
    }

    private var helpText: String {
        self.opensDownloads
            ? L10n.string("Opens this show's downloads in the main window.")
            : L10n.string("Opens this show in the main window.")
    }
}

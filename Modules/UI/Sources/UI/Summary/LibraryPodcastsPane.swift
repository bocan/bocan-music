import AppKit
import Observability
import Persistence
import SwiftUI

// MARK: - LibraryPodcastsPane

/// The Library Summary window's Podcasts tab (#373, phase 26-1): the
/// accounting of a subscription habit. Backlog debt with a projection that
/// is allowed to be terrifying, dead feeds, downloaded-but-never-played
/// hoards, and reapable storage. Follows the other panes' shape: load once,
/// Form sections, rows navigating the main window.
struct LibraryPodcastsPane: View {
    let repository: LibraryStatsRepository
    /// Held as a plain `let`: only used to navigate, never observed.
    let library: LibraryViewModel

    @State private var report: LibraryPodcastReport?
    @State private var loadFailed = false
    @State private var deadExpanded = false
    @State private var hoardExpanded = false

    var body: some View {
        Group {
            if let report {
                self.loadedContent(report)
            } else if self.loadFailed {
                ContentUnavailableView(
                    L10n.string("Summary Unavailable"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(localized: "The library statistics could not be loaded.")
                )
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task { await self.load() }
    }

    @ViewBuilder
    private func loadedContent(_ report: LibraryPodcastReport) -> some View {
        if report.subscribedShowCount == 0 {
            ContentUnavailableView(
                L10n.string("No Podcasts Yet"),
                systemImage: "mic",
                description: Text(localized: "Subscribe to shows and their accounting appears here.")
            )
        } else {
            self.reportForm(report)
        }
    }

    private func reportForm(_ report: LibraryPodcastReport) -> some View {
        Form {
            self.backlogSection(report)
            if !report.deadFeeds.isEmpty {
                self.deadFeedsSection(report)
            }
            if report.unplayedDownloadEpisodeCount > 0 {
                self.hoardSection(report)
            }
            if report.reapableEpisodeCount > 0 {
                self.reapableSection(report)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private func backlogSection(_ report: LibraryPodcastReport) -> some View {
        Section {
            LabeledContent(L10n.string("Unheard backlog"), value: Self.hours(report.backlogSeconds))
            LabeledContent(L10n.string("Listening rate"), value: Self.rate(report.weeklyListeningSeconds))
            LabeledContent(L10n.string("Projection"), value: Self.projection(report))
        } header: {
            Text(localized: "Backlog")
        } footer: {
            Text(Self.rateFootnote)
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private func deadFeedsSection(_ report: LibraryPodcastReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Dead Feeds (\(report.deadFeedCount))"),
                isExpanded: self.$deadExpanded
            ) {
                ForEach(report.deadFeeds) { feed in
                    PodcastShowRow(
                        title: feed.title,
                        detail: L10n.string("Last episode \(Self.monthYear(feed.lastPublishedAt))"),
                        podcastID: feed.id,
                        library: self.library
                    )
                }
                SummaryMoreRow(total: report.deadFeedCount, shown: report.deadFeeds.count)
            }
        } footer: {
            Text(localized: "Still subscribed, still in the sidebar, nothing new in six months.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private func hoardSection(_ report: LibraryPodcastReport) -> some View {
        Section {
            LabeledContent(
                L10n.string("Sitting unheard"),
                value: Self.countAndBytes(report.unplayedDownloadEpisodeCount, report.unplayedDownloadBytes)
            )
            DisclosureGroup(
                L10n.string("By show (\(report.unplayedDownloadShowCount))"),
                isExpanded: self.$hoardExpanded
            ) {
                ForEach(report.unplayedDownloads) { show in
                    PodcastShowRow(
                        title: show.title,
                        detail: Self.countAndBytes(show.episodeCount, show.bytes),
                        podcastID: show.id,
                        library: self.library
                    )
                }
                SummaryMoreRow(total: report.unplayedDownloadShowCount, shown: report.unplayedDownloads.count)
            }
        } header: {
            Text(localized: "Downloaded, Never Played")
        } footer: {
            Text(localized: "The show you think you love versus the show you actually start.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private func reapableSection(_ report: LibraryPodcastReport) -> some View {
        Section {
            LabeledContent(
                L10n.string("Listened, 90+ days old, still on disk"),
                value: Self.countAndBytes(report.reapableEpisodeCount, report.reapableBytes)
            )
        } header: {
            Text(localized: "Reapable Storage")
        } footer: {
            Text(localized: "Already heard, three months cold, still holding disk space.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: - Formatting

    private static let rateFootnote: String = {
        let weeks = LibraryStatsRepository.podcastRateWindowWeeks
        return L10n.string(
            "The rate averages the last \(weeks) weeks and credits each episode's time to its last touch, so treat it as an estimate."
        )
    }()

    /// 1123200 s -> "312 hr".
    private static func hours(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour]
        formatter.unitsStyle = .short
        return formatter.string(from: seconds) ?? String(Int(seconds / 3600))
    }

    private static func rate(_ weeklySeconds: Double) -> String {
        guard weeklySeconds > 0 else { return L10n.string("No recent listening") }
        return L10n.string("\(String(format: "%.1f", weeklySeconds / 3600)) hrs/week")
    }

    private static func projection(_ report: LibraryPodcastReport) -> String {
        guard report.backlogSeconds > 0 else { return L10n.string("Backlog clear") }
        guard report.weeklyListeningSeconds > 0 else {
            return L10n.string("At your current rate: never")
        }
        let weeks = report.backlogSeconds / report.weeklyListeningSeconds
        let months = weeks / 4.345
        if months < 1 { return L10n.string("Under a month") }
        if months > 120 { return L10n.string("Over ten years") }
        return L10n.string("About \(Int(months.rounded(.up))) months")
    }

    private static func countAndBytes(_ count: Int, _ bytes: Int64) -> String {
        L10n.string("\(count.formatted()) episodes · \(bytes.formatted(.byteCount(style: .file)))")
    }

    private static func monthYear(_ epoch: Double) -> String {
        Date(timeIntervalSince1970: epoch).formatted(.dateTime.month(.wide).year())
    }

    // MARK: - Data

    private func load() async {
        do {
            self.report = try await self.repository.fetchPodcastReport()
        } catch {
            self.loadFailed = true
            AppLogger.make(.ui).error(
                "librarySummary.podcasts.load.failed",
                ["error": String(reflecting: error)]
            )
        }
    }
}

// MARK: - PodcastShowRow

/// A summary row that jumps the main window to a podcast show and brings it
/// forward, mirroring `SummaryOffenderRow`'s album navigation.
private struct PodcastShowRow: View {
    let title: String
    let detail: String
    let podcastID: Int64
    /// Held as a plain `let`: only used to navigate, never observed.
    let library: LibraryViewModel

    var body: some View {
        Button {
            Task { await self.library.selectDestination(.podcastShow(self.podcastID)) }
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
        .accessibilityHint(L10n.string("Double-tap to open the show"))
    }
}

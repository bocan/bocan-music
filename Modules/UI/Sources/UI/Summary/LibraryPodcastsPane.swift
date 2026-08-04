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
    @State private var behaviour: LibraryPodcastBehaviourReport?
    @State private var loadFailed = false
    @State private var deadExpanded = false
    @State private var hoardExpanded = false
    @State private var completionExpanded = false
    @State private var creepExpanded = false
    @State private var listenExpanded = false
    @State private var showReapConfirm = false
    @State private var isReaping = false
    @State private var showUnsubscribeConfirm = false
    @State private var feedToUnsubscribe: LibraryPodcastReport.DeadFeed?

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
        .confirmationDialog(
            L10n.string("Delete the reapable downloads?"),
            isPresented: self.$showReapConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Reap"), role: .destructive) {
                Task { await self.reapNow() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(localized: "The audio files are deleted from disk. Episodes and playback history are kept.")
        }
        .confirmationDialog(
            L10n.string("Unsubscribe from \(self.feedToUnsubscribe?.title ?? "")?"),
            isPresented: self.$showUnsubscribeConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Unsubscribe"), role: .destructive) {
                Task { await self.unsubscribeDeadFeed() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(localized: "Episodes and playback history stay; the feed stops refreshing and leaves the sidebar.")
        }
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
            if let behaviour, !behaviour.completions.isEmpty {
                self.completionSection(behaviour)
            }
            if let behaviour, !behaviour.creeps.isEmpty {
                self.creepSection(behaviour)
            }
            if let behaviour, !behaviour.timeToListen.isEmpty {
                self.timeToListenSection(behaviour)
            }
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

    // MARK: - Behaviour sections (phase 26-2)

    private func completionSection(_ behaviour: LibraryPodcastBehaviourReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Completion by Show (\(behaviour.completions.count))"),
                isExpanded: self.$completionExpanded
            ) {
                ForEach(behaviour.completions) { show in
                    PodcastShowRow(
                        title: show.title,
                        detail: Self.completionDetail(show),
                        podcastID: show.id,
                        library: self.library
                    )
                }
            }
        } footer: {
            Text(localized: "Played over started. If the abandonments cluster at the same minute, that is where the ad break is.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private func creepSection(_ behaviour: LibraryPodcastBehaviourReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Length Creep (\(behaviour.creeps.count))"),
                isExpanded: self.$creepExpanded
            ) {
                ForEach(behaviour.creeps) { show in
                    PodcastShowRow(
                        title: show.title,
                        detail: Self.creepDetail(show),
                        podcastID: show.id,
                        library: self.library
                    )
                }
            }
        } footer: {
            Text(localized: "Mean episode length, first qualifying year against the latest. Nearly every successful podcast bloats.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private func timeToListenSection(_ behaviour: LibraryPodcastBehaviourReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Time to Listen (\(behaviour.timeToListen.count))"),
                isExpanded: self.$listenExpanded
            ) {
                ForEach(behaviour.timeToListen) { show in
                    PodcastShowRow(
                        title: show.title,
                        detail: Self.listenDetail(show),
                        podcastID: show.id,
                        library: self.library
                    )
                }
            }
        } footer: {
            Text(
                localized: """
                Median gap from publish to first listen: news at the top, \
                comfort at the bottom. First listens are approximated from \
                the last-played timestamp.
                """
            )
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
                    HStack(spacing: 8) {
                        PodcastShowRow(
                            title: feed.title,
                            detail: L10n.string("Last episode \(Self.monthYear(feed.lastPublishedAt))"),
                            podcastID: feed.id,
                            library: self.library
                        )
                        Button(L10n.string("Unsubscribe…")) {
                            self.feedToUnsubscribe = feed
                            self.showUnsubscribeConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
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
            HStack {
                if self.isReaping {
                    ProgressView()
                        .controlSize(.small)
                    Text(localized: "Reaping…")
                }
                Spacer()
                Button(L10n.string("Reap Now…"), role: .destructive) {
                    self.showReapConfirm = true
                }
                .buttonStyle(.bordered)
                .disabled(self.isReaping)
            }
        } header: {
            Text(localized: "Reapable Storage")
        } footer: {
            Text(localized: "Already heard, three months cold, still holding disk space. Reaping never runs on its own.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: - Actions (phase 26-3)

    /// Deletes every reapable download through the same machinery as the
    /// per-episode Remove Download action, then reloads the accounting.
    private func reapNow() async {
        guard let report, !self.isReaping else { return }
        self.isReaping = true
        defer { self.isReaping = false }
        do {
            let episodes = try await self.repository.fetchReapableEpisodes()
            for episode in episodes {
                await self.library.podcasts.actions?.removeDownload(
                    podcastID: episode.podcastID,
                    guid: episode.guid
                )
            }
            self.library.showToast(ToastMessage(
                text: L10n.string(
                    "Reaped \(episodes.count) episodes, reclaiming \(report.reapableBytes.formatted(.byteCount(style: .file)))"
                ),
                kind: .success
            ))
        } catch {
            AppLogger.make(.ui).error(
                "librarySummary.podcasts.reap.failed",
                ["error": String(reflecting: error)]
            )
        }
        await self.load()
    }

    /// Unsubscribes the confirmed dead feed via the existing path, then
    /// reloads so the row leaves the list.
    private func unsubscribeDeadFeed() async {
        guard let feed = self.feedToUnsubscribe else { return }
        self.feedToUnsubscribe = nil
        await self.library.podcasts.unsubscribe(feed.id)
        self.library.showToast(ToastMessage(
            text: L10n.string("Unsubscribed from \(feed.title)"),
            kind: .info
        ))
        await self.load()
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

    private static func completionDetail(_ show: LibraryPodcastBehaviourReport.ShowCompletion) -> String {
        let rate = show.completionRate.formatted(.percent.precision(.fractionLength(0)))
        guard let abandon = show.meanAbandonSeconds else {
            return L10n.string("\(rate) finished")
        }
        return L10n.string("\(rate) finished · abandons around \(Self.clock(abandon))")
    }

    private static func creepDetail(_ show: LibraryPodcastBehaviourReport.ShowCreep) -> String {
        let delta = show.creep.formatted(.percent.sign(strategy: .always()).precision(.fractionLength(0)))
        let from = Self.minutes(show.firstYearMeanSeconds)
        let to = Self.minutes(show.latestYearMeanSeconds)
        return L10n.string("\(from) in \(String(show.firstYear)) → \(to) in \(String(show.latestYear)) (\(delta))")
    }

    private static func listenDetail(_ show: LibraryPodcastBehaviourReport.ShowTimeToListen) -> String {
        L10n.string("Usually within \(self.gap(show.medianSeconds)) of release · \(show.sampleCount) listens")
    }

    /// 843 s -> "14:03"; over an hour gains the hour figure.
    private static func clock(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? String(Int(seconds))
    }

    /// 2520 s -> "42 min".
    private static func minutes(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: seconds) ?? String(Int(seconds / 60))
    }

    /// One leading unit: "9 hr" under two days, "12 days" beyond.
    private static func gap(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 172_800 ? [.hour, .minute] : [.day]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 1
        return formatter.string(from: max(seconds, 60)) ?? String(Int(seconds / 3600))
    }

    private static func monthYear(_ epoch: Double) -> String {
        Date(timeIntervalSince1970: epoch).formatted(.dateTime.month(.wide).year())
    }

    // MARK: - Data

    private func load() async {
        do {
            self.report = try await self.repository.fetchPodcastReport()
            self.behaviour = try await self.repository.fetchPodcastBehaviour()
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

import Observability
import Persistence
import SwiftUI

// MARK: - LibrarySummaryTab

/// The Library Summary window's sections (#373). Basic Info is live; the
/// rest are placeholders until their data lands.
enum LibrarySummaryTab: String, CaseIterable, Identifiable {
    case basicInfo
    case libraryHygiene
    case audioQuality
    case collectionShape
    case listeningBehaviour
    case podcasts

    var id: String {
        self.rawValue
    }

    /// Localized label shown in the tab strip.
    var displayName: String {
        switch self {
        case .basicInfo:
            L10n.string("Basic Info")

        case .libraryHygiene:
            L10n.string("Library Hygiene")

        case .audioQuality:
            L10n.string("Audio Quality")

        case .collectionShape:
            L10n.string("Collection Shape")

        case .listeningBehaviour:
            L10n.string("Listening Behaviour")

        case .podcasts:
            L10n.string("Podcasts")
        }
    }

    /// SF Symbol shown above the label in the tab strip.
    var systemImage: String {
        switch self {
        case .basicInfo:
            "info.circle"

        case .libraryHygiene:
            "sparkles"

        case .audioQuality:
            "waveform"

        case .collectionShape:
            "chart.pie"

        case .listeningBehaviour:
            "chart.bar.xaxis"

        case .podcasts:
            "mic"
        }
    }
}

// MARK: - LibrarySummaryView

/// Content of the Library Summary window (Tools menu, `⌘⇧Y`): a
/// System-Settings-style tab strip over per-section panes. The Basic Info
/// figures come from ``LibraryStatsRepository`` in one consistent read;
/// they refresh every time the window (re)appears.
public struct LibrarySummaryView: View {
    private let statsRepository: LibraryStatsRepository
    /// Held as a plain `let`: the summary panes navigate through it but never
    /// observe it, so the window doesn't re-render on library churn.
    private let library: LibraryViewModel
    @State private var selection: LibrarySummaryTab = .basicInfo
    @State private var stats: LibrarySummaryStats?
    @State private var loadFailed = false

    public init(database: Database, library: LibraryViewModel) {
        self.statsRepository = LibraryStatsRepository(database: database)
        self.library = library
    }

    public var body: some View {
        VStack(spacing: 0) {
            self.tabStrip
            Divider()
            self.detail(for: self.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 400)
        .task { await self.load() }
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(LibrarySummaryTab.allCases) { tab in
                self.tabButton(tab)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ tab: LibrarySummaryTab) -> some View {
        Button {
            self.selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(tab.displayName)
                    .font(Typography.caption)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 96, height: 52)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.selection == tab ? Color.accentColor : Color.textSecondary)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.selection == tab ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .accessibilityAddTraits(self.selection == tab ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier(A11y.LibrarySummary.tab(tab.rawValue))
    }

    // MARK: - Panes

    @ViewBuilder
    private func detail(for tab: LibrarySummaryTab) -> some View {
        switch tab {
        case .basicInfo:
            self.basicInfoPane

        case .libraryHygiene:
            LibraryHygienePane(repository: self.statsRepository, library: self.library)

        case .audioQuality:
            LibraryAudioQualityPane(repository: self.statsRepository, library: self.library)

        case .collectionShape:
            LibraryCollectionShapePane(repository: self.statsRepository, library: self.library)

        case .listeningBehaviour:
            LibraryListeningBehaviourPane(library: self.library)

        case .podcasts:
            LibraryPodcastsPane(repository: self.statsRepository, library: self.library)
        }
    }

    @ViewBuilder
    private var basicInfoPane: some View {
        if let stats {
            Form {
                Section {
                    LabeledContent(L10n.string("Songs"), value: stats.songCount.formatted())
                    LabeledContent(L10n.string("Albums"), value: stats.albumCount.formatted())
                    LabeledContent(L10n.string("Artists"), value: stats.artistCount.formatted())
                    LabeledContent(L10n.string("Album Artists"), value: stats.albumArtistCount.formatted())
                }
                Section {
                    LabeledContent(
                        L10n.string("Total Playback Duration"),
                        value: Self.durationString(stats.totalDuration)
                    )
                }
            }
            .formStyle(.grouped)
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

    // MARK: - Data

    private func load() async {
        do {
            self.stats = try await self.statsRepository.fetchSummary()
        } catch {
            self.loadFailed = true
            AppLogger.make(.ui).error(
                "librarySummary.load.failed",
                ["error": String(reflecting: error)]
            )
        }
    }

    /// Full-width localized duration, e.g. "38 days, 14 hours, 12 minutes,
    /// 9 seconds". `DateComponentsFormatter` handles pluralisation and locale.
    private static func durationString(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: max(0, interval)) ?? ""
    }
}

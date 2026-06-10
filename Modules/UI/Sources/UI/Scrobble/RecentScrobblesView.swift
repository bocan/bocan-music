import Scrobble
import SwiftUI

// MARK: - RecentScrobblesView

/// Shows the last 50 scrobble-queue entries, their per-provider submission
/// status, and a filter picker to narrow to a single provider.
///
/// Presented as a sheet from `ScrobbleSettingsView` and from the
/// `NowPlayingStrip` pending-scrobbles indicator. The view starts the
/// view model's `observeRecent` stream itself via `appear()`/`disappear()`,
/// so the list is populated no matter which surface presents it.
public struct RecentScrobblesView: View {
    @ObservedObject var viewModel: ScrobbleSettingsViewModel
    @State private var filter: ProviderFilter = .all
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: ScrobbleSettingsViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Provider filter

    private enum ProviderFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case lastfm = "Last.fm"
        case listenbrainz = "ListenBrainz"
        case rocksky = "Rocksky"

        /// Localized segment label; provider names are proper nouns and stay
        /// verbatim (#314).
        var displayName: String {
            self == .all ? L10n.string("All") : self.rawValue
        }

        var id: String {
            self.rawValue
        }

        var providerID: String? {
            switch self {
            case .all:
                nil

            case .lastfm:
                "lastfm"

            case .listenbrainz:
                "listenbrainz"

            case .rocksky:
                "rocksky"
            }
        }
    }

    // MARK: - Filtering

    private var filteredRows: [ScrobbleQueueRepository.RecentRow] {
        guard let pid = self.filter.providerID else {
            return self.viewModel.recentScrobbles
        }
        return self.viewModel.recentScrobbles.filter { $0.statusByProvider[pid] != nil }
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar with title + filter picker + done button
            HStack(spacing: 12) {
                Text(localized: "Recent Scrobbles")
                    .font(.headline)
                Spacer()
                Picker(selection: self.$filter) {
                    ForEach(ProviderFilter.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                    .accessibilityLabel(L10n.string("Filter by provider"))
                Button(L10n.string("Done")) { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Main content
            let rows = self.filteredRows
            if rows.isEmpty {
                ContentUnavailableView(
                    L10n.string("No Scrobbles Yet"),
                    systemImage: "music.note.list",
                    description: Text(localized: "Tracks you play will appear here with their scrobble submission status.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows, id: \.queueID) { row in
                    self.rowView(row)
                }
                .listStyle(.inset)
            }
        }
        .frame(
            minWidth: 620,
            idealWidth: 720,
            maxWidth: .infinity,
            minHeight: 400,
            idealHeight: 520,
            maxHeight: .infinity
        )
        .accessibilityIdentifier("recent-scrobbles")
        .onAppear { self.viewModel.appear() }
        .onDisappear { self.viewModel.disappear() }
    }

    // MARK: - Row view

    @ViewBuilder
    private func rowView(_ row: ScrobbleQueueRepository.RecentRow) -> some View {
        let visibleProviderIDs: [String] = self.filter.providerID.map { [$0] } ?? ["lastfm", "listenbrainz", "rocksky"]

        HStack(alignment: .center, spacing: 10) {
            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(row.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let album = row.album {
                        Text(verbatim: "·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(album)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Relative timestamp
            Text(self.relativeTime(for: row.playedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 70, alignment: .trailing)

            // Per-provider status badges
            HStack(spacing: 6) {
                ForEach(visibleProviderIDs, id: \.self) { pid in
                    if let status = row.statusByProvider[pid] {
                        self.statusBadge(status: status, providerID: pid)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityLabel(for: row, visibleProviderIDs: visibleProviderIDs))
    }

    // MARK: - Status badge

    @ViewBuilder
    private func statusBadge(
        status: ScrobbleQueueRepository.RecentRow.SubmissionStatus,
        providerID: String
    ) -> some View {
        let (imageName, color) = Self.badgeAppearance(for: status)
        let providerName = Self.providerDisplayName(providerID)

        Image(systemName: imageName)
            .foregroundStyle(color)
            .imageScale(.medium)
            .help(L10n.string("\(providerName): \(Self.statusLabel(for: status))"))
            .accessibilityLabel(providerName)
            .accessibilityValue(Self.statusLabel(for: status))
    }

    private static func providerDisplayName(_ providerID: String) -> String {
        switch providerID {
        case "lastfm":
            "Last.fm"

        case "listenbrainz":
            "ListenBrainz"

        case "rocksky":
            "Rocksky"

        default:
            providerID
        }
    }

    /// UI-side labels for the per-provider submission state. The
    /// Scrobble-owned `displayLabel` stays English; translation happens here.
    private static func statusLabel(
        for status: ScrobbleQueueRepository.RecentRow.SubmissionStatus
    ) -> String {
        switch status {
        case .pending:
            L10n.string("Queued")

        case .retry:
            L10n.string("Retrying")

        case .sent:
            L10n.string("Sent")

        case .sentUnconfirmed:
            L10n.string("Sent (unconfirmed)")

        case .failed:
            L10n.string("Failed")

        case .ignored:
            L10n.string("Ignored")
        }
    }

    private static func badgeAppearance(
        for status: ScrobbleQueueRepository.RecentRow.SubmissionStatus
    ) -> (String, Color) {
        switch status {
        case .pending:
            ("clock", .orange)

        case .retry:
            ("arrow.clockwise", .yellow)

        case .sent:
            ("checkmark.circle.fill", .green)

        case .sentUnconfirmed:
            ("checkmark.circle", .green)

        case .failed:
            ("xmark.circle.fill", .red)

        case .ignored:
            ("minus.circle.fill", .secondary)
        }
    }

    // MARK: - Helpers

    private func relativeTime(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func accessibilityLabel(
        for row: ScrobbleQueueRepository.RecentRow,
        visibleProviderIDs: [String]
    ) -> String {
        let time = self.relativeTime(for: row.playedAt)
        let summaryParts: [String] = visibleProviderIDs.compactMap { pid -> String? in
            guard let status = row.statusByProvider[pid] else { return nil }
            let name = pid == "lastfm" ? "Last.fm" : "ListenBrainz"
            return L10n.string("\(name): \(Self.statusLabel(for: status))")
        }
        let providerSummary = summaryParts.joined(separator: ", ")

        var label = L10n.string("\(row.title) by \(row.artist), played \(time)")
        if !providerSummary.isEmpty {
            label += ", \(providerSummary)"
        }
        return label
    }
}

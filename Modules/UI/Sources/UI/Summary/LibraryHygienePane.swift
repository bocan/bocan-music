import AppKit
import Observability
import Persistence
import SwiftUI

// MARK: - LibraryHygienePane

/// The Library Summary window's Library Hygiene tab (#373): actionable
/// tagging and file problems from ``LibraryStatsRepository``'s hygiene
/// detectors, worst offenders first. The offender sections are disclosure
/// groups, collapsed by default so the pane opens as a scannable overview;
/// clicking an offender row jumps the main window to the associated album.
struct LibraryHygienePane: View {
    let repository: LibraryStatsRepository
    /// Held as a plain `let`: only used to navigate, never observed.
    let library: LibraryViewModel

    @State private var report: LibraryHygieneReport?
    @State private var loadFailed = false
    @State private var gapsExpanded = false
    @State private var yearsExpanded = false
    @State private var splitsExpanded = false
    @State private var missingExpanded = false

    var body: some View {
        Group {
            if let report {
                if report.isClean {
                    ContentUnavailableView(
                        L10n.string("No Problems Found"),
                        systemImage: "sparkles",
                        description: Text(localized: "Tags, artwork, and files all look healthy.")
                    )
                } else {
                    self.reportForm(report)
                }
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

    // MARK: - Sections

    private func reportForm(_ report: LibraryHygieneReport) -> some View {
        Form {
            self.completenessSection(report)
            if !report.trackGapAlbums.isEmpty {
                self.gapsSection(report)
            }
            if !report.suspiciousYearTracks.isEmpty {
                self.yearsSection(report)
            }
            if !report.splitAlbums.isEmpty {
                self.splitsSection(report)
            }
            if !report.missingFiles.isEmpty {
                self.missingFilesSection(report)
            }
        }
        .formStyle(.grouped)
    }

    private func completenessSection(_ report: LibraryHygieneReport) -> some View {
        Section(L10n.string("Completeness")) {
            LabeledContent(
                L10n.string("Albums Missing Artwork"),
                value: L10n.string("\(report.albumsMissingArtwork) of \(report.albumCount)")
            )
            LabeledContent(
                L10n.string("Albums Missing Year"),
                value: L10n.string("\(report.albumsMissingYear) of \(report.albumCount)")
            )
            LabeledContent(
                L10n.string("Albums Missing MusicBrainz ID"),
                value: L10n.string("\(report.albumsMissingMusicBrainzID) of \(report.albumCount)")
            )
        }
    }

    private func gapsSection(_ report: LibraryHygieneReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Track Number Gaps (\(report.trackGapAlbumCount))"),
                isExpanded: self.$gapsExpanded
            ) {
                ForEach(report.trackGapAlbums) { album in
                    self.offenderRow(
                        title: album.albumArtistName
                            .map { "\(album.albumTitle) · \($0)" } ?? album.albumTitle,
                        detail: L10n.string(
                            "Missing tracks: \(album.missingTrackNumbers.map(String.init).joined(separator: ", "))"
                        ),
                        albumID: album.id
                    )
                }
                self.moreRow(total: report.trackGapAlbumCount, shown: report.trackGapAlbums.count)
            }
        }
    }

    private func yearsSection(_ report: LibraryHygieneReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Suspicious Years (\(report.suspiciousYearCount))"),
                isExpanded: self.$yearsExpanded
            ) {
                ForEach(report.suspiciousYearTracks) { track in
                    // Years interpolate as pre-rendered strings: a year is a
                    // name, not a quantity, so no grouping separators.
                    self.offenderRow(
                        title: track.albumTitle
                            .map { "\(track.trackTitle) · \($0)" } ?? track.trackTitle,
                        detail: track.albumYear
                            .map { L10n.string("Year \(String(track.year)), album says \(String($0))") }
                            ?? L10n.string("Year \(String(track.year))"),
                        albumID: track.albumID
                    )
                }
                self.moreRow(total: report.suspiciousYearCount, shown: report.suspiciousYearTracks.count)
            }
        }
    }

    private func splitsSection(_ report: LibraryHygieneReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Split Albums (\(report.splitAlbumCount))"),
                isExpanded: self.$splitsExpanded
            ) {
                ForEach(report.splitAlbums) { group in
                    self.offenderRow(
                        title: group.title,
                        detail: L10n.string("Appears as \(group.variantCount) separate albums"),
                        albumID: group.primaryAlbumID
                    )
                }
                self.moreRow(total: report.splitAlbumCount, shown: report.splitAlbums.count)
            }
        }
    }

    private func missingFilesSection(_ report: LibraryHygieneReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Missing Files (\(report.missingFileCount))"),
                isExpanded: self.$missingExpanded
            ) {
                ForEach(report.missingFiles) { track in
                    self.offenderRow(
                        title: track.trackTitle,
                        detail: URL(string: track.fileURL)?.lastPathComponent ?? track.fileURL,
                        albumID: track.albumID
                    )
                }
                self.moreRow(total: report.missingFileCount, shown: report.missingFiles.count)
            }
        }
    }

    // MARK: - Rows

    /// An offender row. With an `albumID` it becomes a button that jumps the
    /// main window to that album; without one it renders as plain text.
    @ViewBuilder
    private func offenderRow(title: String, detail: String, albumID: Int64?) -> some View {
        if let albumID {
            Button {
                self.openAlbum(albumID)
            } label: {
                HStack(spacing: 6) {
                    self.rowText(title: title, detail: detail)
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
            self.rowText(title: title, detail: detail)
        }
    }

    private func rowText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Text(detail)
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func moreRow(total: Int, shown: Int) -> some View {
        if total > shown {
            Text(localized: "and \(total - shown) more")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: - Navigation

    /// Jumps the main window to `albumID` and brings it forward; the summary
    /// window stays open so the user can work through the list.
    private func openAlbum(_ albumID: Int64) {
        Task { await self.library.selectDestination(.album(albumID)) }
        MainWindowTracker.shared.resolveWindow()?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Data

    private func load() async {
        do {
            self.report = try await self.repository.fetchHygiene()
        } catch {
            self.loadFailed = true
            AppLogger.make(.ui).error(
                "librarySummary.hygiene.load.failed",
                ["error": String(reflecting: error)]
            )
        }
    }
}

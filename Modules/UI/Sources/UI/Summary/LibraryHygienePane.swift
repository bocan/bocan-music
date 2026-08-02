import Observability
import Persistence
import SwiftUI

// MARK: - LibraryHygienePane

/// The Library Summary window's Library Hygiene tab (#373, slice one):
/// actionable tagging and file problems from ``LibraryStatsRepository``'s
/// hygiene detectors, worst offenders first. Offender lists are capped by
/// the repository; the section headers carry the uncapped totals.
struct LibraryHygienePane: View {
    let repository: LibraryStatsRepository
    @State private var report: LibraryHygieneReport?
    @State private var loadFailed = false

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
        Section(L10n.string("Track Number Gaps (\(report.trackGapAlbumCount))")) {
            ForEach(report.trackGapAlbums) { album in
                self.offenderRow(
                    title: album.albumArtistName
                        .map { "\(album.albumTitle) · \($0)" } ?? album.albumTitle,
                    detail: L10n.string(
                        "Missing tracks: \(album.missingTrackNumbers.map(String.init).joined(separator: ", "))"
                    )
                )
            }
            self.moreRow(total: report.trackGapAlbumCount, shown: report.trackGapAlbums.count)
        }
    }

    private func yearsSection(_ report: LibraryHygieneReport) -> some View {
        Section(L10n.string("Suspicious Years (\(report.suspiciousYearCount))")) {
            ForEach(report.suspiciousYearTracks) { track in
                self.offenderRow(
                    title: track.albumTitle
                        .map { "\(track.trackTitle) · \($0)" } ?? track.trackTitle,
                    detail: track.albumYear
                        .map { L10n.string("Year \(track.year), album says \($0)") }
                        ?? L10n.string("Year \(track.year)")
                )
            }
            self.moreRow(total: report.suspiciousYearCount, shown: report.suspiciousYearTracks.count)
        }
    }

    private func splitsSection(_ report: LibraryHygieneReport) -> some View {
        Section(L10n.string("Split Albums (\(report.splitAlbumCount))")) {
            ForEach(report.splitAlbums) { group in
                self.offenderRow(
                    title: group.title,
                    detail: L10n.string("Appears as \(group.variantCount) separate albums")
                )
            }
            self.moreRow(total: report.splitAlbumCount, shown: report.splitAlbums.count)
        }
    }

    private func missingFilesSection(_ report: LibraryHygieneReport) -> some View {
        Section(L10n.string("Missing Files (\(report.missingFileCount))")) {
            ForEach(report.missingFiles) { track in
                self.offenderRow(
                    title: track.trackTitle,
                    detail: URL(string: track.fileURL)?.lastPathComponent ?? track.fileURL
                )
            }
            self.moreRow(total: report.missingFileCount, shown: report.missingFiles.count)
        }
    }

    // MARK: - Rows

    private func offenderRow(title: String, detail: String) -> some View {
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

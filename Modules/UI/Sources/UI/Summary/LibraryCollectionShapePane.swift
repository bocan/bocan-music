import Observability
import Persistence
import SwiftUI

// MARK: - LibraryCollectionShapePane

/// The Library Summary window's Collection Shape tab (#373): when the music
/// was made, ownership versus listening per decade, how deep each artist
/// runs, and the outliers. Follows the other panes' shape: load once, Form
/// sections, offender-style rows navigating to albums.
struct LibraryCollectionShapePane: View {
    let repository: LibraryStatsRepository
    /// Held as a plain `let`: only used to navigate, never observed.
    let library: LibraryViewModel

    @State private var report: LibraryCollectionShapeReport?
    @State private var loadFailed = false

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
    private func loadedContent(_ report: LibraryCollectionShapeReport) -> some View {
        if report.artistCount == 0, report.years.isEmpty, report.longestTrack == nil {
            ContentUnavailableView(
                L10n.string("Nothing to Measure"),
                systemImage: "music.note.list",
                description: Text(localized: "Add music to the library and its shape will appear here.")
            )
        } else {
            self.reportForm(report)
        }
    }

    private func reportForm(_ report: LibraryCollectionShapeReport) -> some View {
        Form {
            if !report.years.isEmpty {
                self.yearsSection(report)
            }
            if !report.decades.isEmpty {
                self.decadesSection(report)
            }
            self.artistDepthSection(report)
            if !report.deepestArtists.isEmpty {
                self.deepestSection(report)
            }
            self.extremesSection(report)
            if !report.albumLengthByDecade.isEmpty {
                self.albumLengthSection(report)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private func yearsSection(_ report: LibraryCollectionShapeReport) -> some View {
        Section {
            YearHistogramChart(years: report.years)
                .padding(.vertical, 4)
        } header: {
            Text(localized: "Release Years")
        } footer: {
            if report.undatedTrackCount > 0 {
                Text(localized: "No usable year on \(report.undatedTrackCount) tracks")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    private func decadesSection(_ report: LibraryCollectionShapeReport) -> some View {
        Section {
            DecadeStripsChart(decades: report.decades)
                .padding(.vertical, 4)
        } header: {
            Text(localized: "Owned vs Played by Decade")
        } footer: {
            Text(localized: "Where the strips disagree, your shelf and your taste part ways.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private func artistDepthSection(_ report: LibraryCollectionShapeReport) -> some View {
        Section(L10n.string("Artist Depth")) {
            LabeledContent(L10n.string("Artists"), value: report.artistCount.formatted())
            LabeledContent(
                L10n.string("One-track artists"),
                value: Self.countAndShare(report.singleTrackArtistCount, of: report.artistCount)
            )
            LabeledContent(
                L10n.string("Artists with \(LibraryStatsRepository.deepArtistAlbumThreshold)+ albums"),
                value: report.deepArtistCount.formatted()
            )
        }
    }

    private func deepestSection(_ report: LibraryCollectionShapeReport) -> some View {
        Section(L10n.string("Deepest Catalogues")) {
            ForEach(report.deepestArtists) { artist in
                LabeledContent(
                    artist.name,
                    value: L10n.string("\(artist.albumCount.formatted()) albums")
                )
            }
        }
    }

    @ViewBuilder
    private func extremesSection(_ report: LibraryCollectionShapeReport) -> some View {
        if report.longestTrack != nil || report.longestAlbum != nil {
            Section(L10n.string("Extremes")) {
                if let track = report.longestTrack {
                    self.extremeTrackRow(track, caption: L10n.string("Longest song · \(Self.clock(track.duration))"))
                }
                if let track = report.shortestTrack, track.id != report.longestTrack?.id {
                    self.extremeTrackRow(track, caption: L10n.string("Shortest song · \(Self.clock(track.duration))"))
                }
                if let album = report.longestAlbum {
                    SummaryOffenderRow(
                        title: album.albumArtistName
                            .map { "\(album.albumTitle) · \($0)" } ?? album.albumTitle,
                        detail: Self.longestAlbumDetail(album),
                        albumID: album.id,
                        library: self.library
                    )
                }
            }
        }
    }

    private func extremeTrackRow(
        _ track: LibraryCollectionShapeReport.ExtremeTrack,
        caption: String
    ) -> some View {
        SummaryOffenderRow(
            title: track.albumTitle
                .map { "\(track.trackTitle) · \($0)" } ?? track.trackTitle,
            detail: caption,
            albumID: track.albumID,
            library: self.library,
            trackID: track.id
        )
    }

    private func albumLengthSection(_ report: LibraryCollectionShapeReport) -> some View {
        Section {
            let longest = report.albumLengthByDecade.map(\.averageSeconds).max() ?? 1
            ForEach(report.albumLengthByDecade) { entry in
                self.albumLengthRow(entry, longestAverage: longest)
            }
        } header: {
            Text(localized: "Average Album Length by Decade")
        } footer: {
            Text(Self.albumLengthFooter)
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private static let albumLengthFooter: String = {
        let minimum = LibraryStatsRepository.minimumAlbumTracksForLength
        return L10n.string("Albums with at least \(minimum) tracks. Watch the average climb when the CD arrives, then fall again.")
    }()

    private func albumLengthRow(
        _ entry: LibraryCollectionShapeReport.DecadeAlbumLength,
        longestAverage: Double
    ) -> some View {
        HStack(spacing: 8) {
            Text(CollectionShapeStyle.decadeLabel(entry.decade))
                .font(.callout.monospacedDigit())
                .frame(width: 52, alignment: .leading)
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(3, proxy.size.width * CGFloat(entry.averageSeconds / max(longestAverage, 1))))
                    .frame(maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: 8)
            Text(L10n.string("\(Self.minutes(entry.averageSeconds)) · \(entry.albumCount.formatted()) albums"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .layoutPriority(1)
        }
    }

    // MARK: - Formatting

    /// "45 · 12%" style count-with-share for the depth rows.
    private static func countAndShare(_ count: Int, of total: Int) -> String {
        let share = CollectionShapeStyle.percent(Double(count), of: Double(total))
        return L10n.string("\(count.formatted()) (\(share))")
    }

    private static func longestAlbumDetail(_ album: LibraryCollectionShapeReport.ExtremeAlbum) -> String {
        let length = Self.hoursMinutes(album.totalSeconds)
        return L10n.string("Longest album · \(length) · \(album.trackCount.formatted()) songs")
    }

    /// 4103 s -> "1:08:23"; 243 s -> "4:03".
    private static func clock(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? String(Int(seconds))
    }

    /// 7380 s -> "2h 3m".
    private static func hoursMinutes(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? String(Int(seconds))
    }

    /// 2520 s -> "42 min".
    private static func minutes(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: seconds) ?? String(Int(seconds / 60))
    }

    // MARK: - Data

    private func load() async {
        do {
            self.report = try await self.repository.fetchCollectionShape()
        } catch {
            self.loadFailed = true
            AppLogger.make(.ui).error(
                "librarySummary.collectionShape.load.failed",
                ["error": String(reflecting: error)]
            )
        }
    }
}

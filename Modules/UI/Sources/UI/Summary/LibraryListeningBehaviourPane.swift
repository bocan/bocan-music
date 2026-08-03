import Observability
import Persistence
import SwiftUI

// MARK: - LibraryListeningBehaviourPane

/// The Library Summary window's Listening Behaviour tab (#373): the
/// imported-history ledger (phase 25-1) and the counter analytics built on
/// it (25-2): utilisation and the Gini coefficient, the skip-rate delete
/// candidates, dormant favourites, and abandoned albums. Heatmaps and
/// discovery charts follow in 25-3.
struct LibraryListeningBehaviourPane: View {
    /// Observed so the import-in-flight spinner and completion refresh work.
    @ObservedObject var library: LibraryViewModel

    @State private var counts: ListenImportRepository.Counts?
    @State private var report: LibraryListeningReport?
    @State private var time: LibraryListeningTimeReport?
    @State private var showRemoveConfirm = false
    @State private var skipsExpanded = false
    @State private var dormantExpanded = false
    @State private var abandonedExpanded = false

    var body: some View {
        Form {
            self.importedHistorySection
            if let report, report.playedTrackCount > 0 {
                self.utilisationSection(report)
            }
            if let time, time.totalPlays > 0 {
                self.whenYouListenSection(time)
            }
            if let time, time.discoveryByMonth.count > 1 {
                self.discoverySection(time)
            }
            if let report, !report.skipCandidates.isEmpty {
                self.skipSection(report)
            }
            if let report, !report.dormantFavourites.isEmpty {
                self.dormantSection(report)
            }
            if let report, !report.abandonedAlbums.isEmpty {
                self.abandonedSection(report)
            }
            if let time, !time.seasonalArtists.isEmpty {
                self.seasonalSection(time)
            }
        }
        .formStyle(.grouped)
        .task { await self.load() }
        .onChange(of: self.library.isImportingListens) { _, importing in
            guard !importing else { return }
            Task { await self.load() }
        }
        .confirmationDialog(
            L10n.string("Remove all imported listening history?"),
            isPresented: self.$showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove Imported History"), role: .destructive) {
                Task {
                    await self.library.removeImportedListens()
                    await self.load()
                }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(localized: "Locally recorded plays are not affected.")
        }
    }

    // MARK: - Sections

    private var importedHistorySection: some View {
        Section {
            if self.library.isImportingListens {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(localized: "Importing listening history…")
                }
            } else if let counts, counts.total > 0 {
                self.countRows(counts)
                self.actionsRow
            } else {
                HStack {
                    Text(localized: "No listening history imported yet")
                    Spacer()
                    self.importButton
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(localized: "Imported History")
        } footer: {
            self.footer
        }
    }

    @ViewBuilder
    private func countRows(_ counts: ListenImportRepository.Counts) -> some View {
        LabeledContent(L10n.string("Imported listens"), value: counts.total.formatted())
        LabeledContent(L10n.string("Matched to your library"), value: Self.matchedValue(counts))
        if counts.unmatched > 0 {
            LabeledContent(L10n.string("Awaiting a match"), value: counts.unmatched.formatted())
        }
    }

    private var actionsRow: some View {
        HStack {
            self.importButton
            Button(L10n.string("Match Again")) {
                Task {
                    await self.library.rematchImportedListens()
                    await self.load()
                }
            }
            .buttonStyle(.bordered)
            .help(L10n.string("Try to link unmatched listens after adding music to the library"))
            Spacer()
            Button(L10n.string("Remove…"), role: .destructive) {
                self.showRemoveConfirm = true
            }
            .buttonStyle(.bordered)
        }
    }

    private var importButton: some View {
        Button(L10n.string("Import Last.fm Export…")) {
            Task { await self.library.importListeningHistoryByPicker() }
        }
        .buttonStyle(.bordered)
    }

    private var footer: some View {
        Text(
            localized: """
            Imported plays stay separate from local play counts. Unmatched \
            listens are kept, and Match Again links them up after your \
            library grows.
            """
        )
        .font(Typography.caption)
        .foregroundStyle(Color.textTertiary)
    }

    // MARK: - Analytics sections (phase 25-2)

    private func utilisationSection(_ report: LibraryListeningReport) -> some View {
        Section {
            LabeledContent(
                L10n.string("Songs ever played"),
                value: Self.utilisationValue(report)
            )
            if let gini = report.giniCoefficient {
                LabeledContent(
                    L10n.string("Play-count concentration (Gini)"),
                    value: String(format: "%.2f", gini)
                )
            }
        } header: {
            Text(localized: "Library Utilisation")
        } footer: {
            Text(
                localized: """
                Gini: 0 means every song gets equal rotation, 1 means one song \
                took every play. Most libraries land north of 0.7 once a few \
                hundred favourites do all the work. Matched imported listens \
                count toward lifetime plays throughout.
                """
            )
            .font(Typography.caption)
            .foregroundStyle(Color.textTertiary)
        }
    }

    private func skipSection(_ report: LibraryListeningReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Skip Candidates (\(report.skipCandidateCount))"),
                isExpanded: self.$skipsExpanded
            ) {
                ForEach(report.skipCandidates) { track in
                    SummaryOffenderRow(
                        title: track.albumTitle
                            .map { "\(track.trackTitle) · \($0)" } ?? track.trackTitle,
                        detail: Self.skipDetail(track),
                        albumID: track.albumID,
                        library: self.library
                    )
                }
                SummaryMoreRow(total: report.skipCandidateCount, shown: report.skipCandidates.count)
            }
        } footer: {
            Text(localized: "A play only counts past half the song, so these were abandoned early, repeatedly.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private func dormantSection(_ report: LibraryListeningReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Dormant Favourites (\(report.dormantFavouriteCount))"),
                isExpanded: self.$dormantExpanded
            ) {
                ForEach(report.dormantFavourites) { track in
                    SummaryOffenderRow(
                        title: track.albumTitle
                            .map { "\(track.trackTitle) · \($0)" } ?? track.trackTitle,
                        detail: Self.dormantDetail(track),
                        albumID: track.albumID,
                        library: self.library
                    )
                }
                SummaryMoreRow(total: report.dormantFavouriteCount, shown: report.dormantFavourites.count)
            }
        } footer: {
            Text(localized: "Songs you loved that have gone silent for two years. The rediscovery list.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private func abandonedSection(_ report: LibraryListeningReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Abandoned Albums (\(report.abandonedAlbumCount))"),
                isExpanded: self.$abandonedExpanded
            ) {
                ForEach(report.abandonedAlbums) { album in
                    SummaryOffenderRow(
                        title: album.albumArtistName
                            .map { "\(album.albumTitle) · \($0)" } ?? album.albumTitle,
                        detail: L10n.string("Never past track \(album.playedThroughTrack) of \(album.trackCount)"),
                        albumID: album.id,
                        library: self.library
                    )
                }
                SummaryMoreRow(total: report.abandonedAlbumCount, shown: report.abandonedAlbums.count)
            }
        } footer: {
            Text(localized: "You never got past the singles. Albums where nothing beyond the leading tracks was ever played.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: - Time sections (phase 25-3)

    private func whenYouListenSection(_ time: LibraryListeningTimeReport) -> some View {
        Section {
            HourWeekdayHeatmap(cells: time.heatmap)
                .padding(.vertical, 4)
        } header: {
            Text(localized: "When You Listen")
        } footer: {
            Text(
                localized: """
                Every play, local and imported, bucketed in your current time \
                zone. Plays scrobbled from another time zone shift by the \
                offset.
                """
            )
            .font(Typography.caption)
            .foregroundStyle(Color.textTertiary)
        }
    }

    private func discoverySection(_ time: LibraryListeningTimeReport) -> some View {
        Section {
            DiscoveryLineChart(months: time.discoveryByMonth)
                .padding(.vertical, 4)
        } header: {
            Text(localized: "Discovery Rate")
        } footer: {
            Text(localized: "Artists heard for the first time each month. Unmatched scrobbles count too.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private func seasonalSection(_ time: LibraryListeningTimeReport) -> some View {
        Section {
            ForEach(time.seasonalArtists) { artist in
                LabeledContent(artist.name, value: Self.seasonalValue(artist))
            }
        } header: {
            Text(localized: "Seasonal Listening")
        } footer: {
            Text(localized: "Artists whose plays pile into one month of the year, seen across at least two years.")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: - Formatting

    private static func seasonalValue(_ artist: LibraryListeningTimeReport.SeasonalArtist) -> String {
        let share = artist.share.formatted(.percent.precision(.fractionLength(0)))
        let month = Calendar.current.monthSymbols[artist.peakMonth - 1]
        return L10n.string("\(share) in \(month) · \(artist.totalPlays.formatted()) plays")
    }

    private static func utilisationValue(_ report: LibraryListeningReport) -> String {
        let share = report.trackCount > 0
            ? (Double(report.playedTrackCount) / Double(report.trackCount))
            .formatted(.percent.precision(.fractionLength(0)))
            : 0.formatted(.percent)
        return L10n.string("\(report.playedTrackCount.formatted()) of \(report.trackCount.formatted()) (\(share))")
    }

    private static func skipDetail(_ track: LibraryListeningReport.SkipCandidate) -> String {
        guard let bail = track.averageBailSeconds else {
            return L10n.string("\(track.skipCount) skips vs \(track.playCount) plays")
        }
        let clock = Duration.seconds(bail).formatted(.time(pattern: .minuteSecond))
        return L10n.string("\(track.skipCount) skips vs \(track.playCount) plays · bails around \(clock)")
    }

    private static func dormantDetail(_ track: LibraryListeningReport.DormantFavourite) -> String {
        let when = Date(timeIntervalSince1970: TimeInterval(track.lastPlayedAt))
            .formatted(.dateTime.month(.wide).year())
        return L10n.string("\(track.lifetimePlays) plays · last heard \(when)")
    }

    private static func matchedValue(_ counts: ListenImportRepository.Counts) -> String {
        let share = counts.total > 0
            ? (Double(counts.matched) / Double(counts.total)).formatted(.percent.precision(.fractionLength(0)))
            : 0.formatted(.percent)
        return L10n.string("\(counts.matched.formatted()) (\(share))")
    }

    // MARK: - Data

    private func load() async {
        do {
            self.counts = try await ListenImportRepository(database: self.library.database).counts()
            self.report = try await LibraryStatsRepository(database: self.library.database)
                .fetchListeningBehaviour()
            self.time = try await LibraryStatsRepository(database: self.library.database)
                .fetchListeningTime()
        } catch {
            AppLogger.make(.ui).error(
                "librarySummary.listening.load.failed",
                ["error": String(reflecting: error)]
            )
        }
    }
}

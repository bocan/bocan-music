import Library
import SwiftUI

// MARK: - DeepDiveTrackView

/// The recording Deep Dive report for a single track (#413).
struct DeepDiveTrackView: View {
    @ObservedObject var vm: DeepDiveTrackViewModel

    var body: some View {
        Group {
            switch self.vm.state {
            case .idle, .loading:
                DeepDiveProgressView(retry: nil)

            case let .retrying(attempt, total):
                DeepDiveProgressView(retry: (attempt, total))

            case let .failed(error):
                DeepDiveErrorView(message: DeepDiveFormat.errorMessage(error)) { self.vm.load(forceRefresh: true) }

            case let .loaded(report):
                self.report(report)
            }
        }
        .task {
            if case .idle = self.vm.state { self.vm.load() }
        }
    }

    private func report(_ report: TrackReport) -> some View {
        Form {
            self.recordingSection(report)
            if !report.works.isEmpty {
                self.worksSection(report.works)
            }
            if !report.appearances.isEmpty {
                self.appearancesSection(report.appearances)
            }
            if let acoustID = report.acoustIDURL {
                Section(L10n.string("Links")) {
                    Link(L10n.string("AcoustID"), destination: acoustID)
                }
            }
            DeepDiveFooter(fetchedAt: report.fetchedAt, helpText: L10n.string("Fetch the report again from MusicBrainz")) {
                self.vm.load(forceRefresh: true)
            }
        }
        .formStyle(.grouped)
    }

    private func recordingSection(_ report: TrackReport) -> some View {
        Section(L10n.string("Recording")) {
            LabeledContent(L10n.string("Title"), value: report.title)
            LabeledContent(L10n.string("Artist credit"), value: report.artistCredit)
            if let length = report.length {
                LabeledContent(L10n.string("Length"), value: Self.formatLength(length))
            }
            if let year = report.firstReleaseYear {
                LabeledContent(L10n.string("First released"), value: String(year))
            }
            if !report.isrcs.isEmpty {
                LabeledContent(L10n.string("ISRC"), value: report.isrcs.joined(separator: ", "))
            }
            if !report.tags.isEmpty {
                LabeledContent(L10n.string("Tags"), value: report.tags.joined(separator: ", "))
            }
            ReadOnlyIDRow(label: L10n.string("Recording MBID"), value: report.recordingMBID)
        }
    }

    private func worksSection(_ works: [TrackReport.Work]) -> some View {
        Section(L10n.string("Written by")) {
            ForEach(works, id: \.mbid) { work in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: work.title)
                    Text(verbatim: Self.credits(work))
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
    }

    private static func credits(_ work: TrackReport.Work) -> String {
        var parts: [String] = []
        if !work.composers.isEmpty { parts.append(L10n.string("Composer: \(work.composers.joined(separator: ", "))")) }
        if !work.lyricists.isEmpty { parts.append(L10n.string("Lyricist: \(work.lyricists.joined(separator: ", "))")) }
        if !work.writers.isEmpty { parts.append(L10n.string("Writer: \(work.writers.joined(separator: ", "))")) }
        return parts.isEmpty ? L10n.string("No writer credits on MusicBrainz") : parts.joined(separator: " · ")
    }

    private func appearancesSection(_ appearances: [TrackReport.Appearance]) -> some View {
        Section(L10n.string("Appears on")) {
            ForEach(appearances, id: \.releaseMBID) { appearance in
                HStack {
                    Text(verbatim: appearance.releaseTitle)
                    Spacer()
                    Text(verbatim: Self.kindAndCountry(appearance))
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                    DeepDiveYear(year: appearance.year)
                }
            }
        }
    }

    private static func kindAndCountry(_ appearance: TrackReport.Appearance) -> String {
        [
            DeepDiveFormat.releaseKind(appearance.primaryType, secondary: appearance.secondaryTypes),
            appearance.country ?? "",
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func formatLength(_ milliseconds: Int) -> String {
        let total = milliseconds / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

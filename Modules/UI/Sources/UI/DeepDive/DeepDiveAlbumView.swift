import Library
import SwiftUI

// MARK: - DeepDiveAlbumView

/// The release Deep Dive report for an album (#413).
struct DeepDiveAlbumView: View {
    @ObservedObject var vm: DeepDiveAlbumViewModel

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

    private func report(_ report: AlbumReport) -> some View {
        Form {
            self.releaseSection(report)
            if !report.labels.isEmpty || !report.formats.isEmpty {
                self.pressingSection(report)
            }
            if !report.nearby.isEmpty {
                self.nearbySection(report.nearby)
            }
            Section(L10n.string("Links")) {
                Link(L10n.string("MusicBrainz"), destination: report.musicBrainzURL)
                Link(L10n.string("Cover Art Archive"), destination: report.coverArtArchiveURL)
            }
            DeepDiveFooter(fetchedAt: report.fetchedAt, helpText: L10n.string("Fetch the report again from MusicBrainz")) {
                self.vm.load(forceRefresh: true)
            }
        }
        .formStyle(.grouped)
    }

    private func releaseSection(_ report: AlbumReport) -> some View {
        Section(L10n.string("Release")) {
            if report.releaseChosen {
                Label(
                    L10n.string("The tags name only the release group; showing its earliest official release."),
                    systemImage: "info.circle"
                )
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
            }
            LabeledContent(L10n.string("Title"), value: report.title)
            LabeledContent(L10n.string("Artist"), value: report.artistName)
            LabeledContent(L10n.string("Kind"), value: DeepDiveFormat.releaseKind(report.primaryType, secondary: report.secondaryTypes))
            if let date = report.date {
                LabeledContent(L10n.string("Date"), value: date)
            }
            if let country = report.country {
                LabeledContent(L10n.string("Country"), value: country)
            }
            if let status = report.status {
                LabeledContent(L10n.string("Status"), value: status)
            }
            LabeledContent(L10n.string("Tracks"), value: self.trackCountText(report))
            ReadOnlyIDRow(label: L10n.string("Release MBID"), value: report.releaseMBID)
        }
    }

    private func pressingSection(_ report: AlbumReport) -> some View {
        Section(L10n.string("Pressing")) {
            ForEach(Array(report.labels.enumerated()), id: \.offset) { _, label in
                LabeledContent(L10n.string("Label"), value: label.catalogNumber.map { "\(label.name) · \($0)" } ?? label.name)
            }
            if !report.formats.isEmpty {
                LabeledContent(L10n.string("Format"), value: report.formats.joined(separator: " + "))
            }
            if let barcode = report.barcode {
                LabeledContent(L10n.string("Barcode"), value: barcode)
            }
        }
    }

    private func nearbySection(_ nearby: [AlbumReport.Nearby]) -> some View {
        Section(L10n.string("Around the same time")) {
            ForEach(nearby, id: \.mbid) { release in
                HStack {
                    Image(systemName: release.owned ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(release.owned ? Color.accentColor : Color.textTertiary)
                        .accessibilityLabel(release.owned ? L10n.string("In your library") : L10n.string("Not in your library"))
                    Text(verbatim: release.title)
                    Spacer()
                    Text(verbatim: DeepDiveFormat.releaseKind(release.primaryType, secondary: []))
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                    DeepDiveYear(year: release.year)
                }
            }
        }
    }

    private func trackCountText(_ report: AlbumReport) -> String {
        guard let total = report.trackCount else { return String(report.ownedTrackCount) }
        return L10n.string("\(report.ownedTrackCount) of \(total) in your library")
    }
}

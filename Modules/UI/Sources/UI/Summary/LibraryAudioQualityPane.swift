import Observability
import Persistence
import SwiftUI

// MARK: - LibraryAudioQualityPane

/// The Library Summary window's Audio Quality tab (#373): what the library
/// is made of (codec, fidelity, and lossless share, by count and by bytes)
/// and the tracks worth a second look. Follows the hygiene pane's shape:
/// distributions up top, offender lists as disclosure groups collapsed by
/// default, offender rows navigating the main window to their album.
struct LibraryAudioQualityPane: View {
    let repository: LibraryStatsRepository
    /// Held as a plain `let`: only used to navigate, never observed.
    let library: LibraryViewModel

    @State private var report: LibraryAudioQualityReport?
    @State private var loadFailed = false
    @State private var mixedExpanded = false
    @State private var oversExpanded = false

    var body: some View {
        Group {
            if let report {
                self.reportForm(report)
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

    private func reportForm(_ report: LibraryAudioQualityReport) -> some View {
        Form {
            self.losslessSection(report)
            self.formatsSection(report)
            self.fidelitySection(report)
            if !report.mixedFormatAlbums.isEmpty {
                self.mixedSection(report)
            }
            if !report.truePeakOvers.isEmpty || report.unanalysedTrackCount > 0 {
                self.oversSection(report)
            }
        }
        .formStyle(.grouped)
    }

    private func losslessSection(_ report: LibraryAudioQualityReport) -> some View {
        Section(L10n.string("Lossless vs Lossy")) {
            LabeledContent(
                L10n.string("Lossless"),
                value: Self.countAndBytes(report.losslessCount, report.losslessBytes)
            )
            LabeledContent(
                L10n.string("Lossy"),
                value: Self.countAndBytes(report.lossyCount, report.lossyBytes)
            )
            if report.unknownCount > 0 {
                LabeledContent(
                    L10n.string("Unknown"),
                    value: Self.countAndBytes(report.unknownCount, report.unknownBytes)
                )
            }
        }
    }

    private func formatsSection(_ report: LibraryAudioQualityReport) -> some View {
        Section(L10n.string("Formats")) {
            ForEach(report.formats) { slice in
                LabeledContent(
                    slice.format.uppercased(),
                    value: Self.countAndBytes(slice.count, slice.bytes)
                )
            }
        }
    }

    private func fidelitySection(_ report: LibraryAudioQualityReport) -> some View {
        Section(L10n.string("Fidelity")) {
            ForEach(report.sampleRates) { slice in
                LabeledContent(
                    L10n.string("\(Self.kHz(slice.value)) kHz"),
                    value: slice.count.formatted()
                )
            }
            ForEach(report.bitDepths) { slice in
                LabeledContent(
                    L10n.string("\(slice.value)-bit"),
                    value: slice.count.formatted()
                )
            }
            ForEach(report.lossyBitrates) { slice in
                LabeledContent(
                    L10n.string("\(slice.value) kbps"),
                    value: slice.count.formatted()
                )
            }
        }
    }

    private func mixedSection(_ report: LibraryAudioQualityReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("Mixed-Format Albums (\(report.mixedFormatAlbumCount))"),
                isExpanded: self.$mixedExpanded
            ) {
                ForEach(report.mixedFormatAlbums) { album in
                    SummaryOffenderRow(
                        title: album.albumArtistName
                            .map { "\(album.albumTitle) · \($0)" } ?? album.albumTitle,
                        detail: album.formats.map { $0.uppercased() }.joined(separator: " + "),
                        albumID: album.id,
                        library: self.library
                    )
                }
                SummaryMoreRow(total: report.mixedFormatAlbumCount, shown: report.mixedFormatAlbums.count)
            }
        }
    }

    private func oversSection(_ report: LibraryAudioQualityReport) -> some View {
        Section {
            DisclosureGroup(
                L10n.string("True-Peak Overs (\(report.truePeakOverCount))"),
                isExpanded: self.$oversExpanded
            ) {
                ForEach(report.truePeakOvers) { track in
                    SummaryOffenderRow(
                        title: track.albumTitle
                            .map { "\(track.trackTitle) · \($0)" } ?? track.trackTitle,
                        detail: L10n.string("Peaks at +\(Self.dBTP(track.truePeakLinear)) dBTP"),
                        albumID: track.albumID,
                        library: self.library
                    )
                }
                SummaryMoreRow(total: report.truePeakOverCount, shown: report.truePeakOvers.count)
            }
        } footer: {
            if report.unanalysedTrackCount > 0 {
                Text(localized: "Not yet analysed: \(report.unanalysedTrackCount) tracks")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    // MARK: - Formatting

    /// "12,345 songs · 210.4 GB", localized in both halves.
    private static func countAndBytes(_ count: Int, _ bytes: Int64) -> String {
        L10n.string("\(count.formatted()) songs · \(bytes.formatted(.byteCount(style: .file)))")
    }

    /// 44100 -> "44.1", 96000 -> "96".
    private static func kHz(_ hertz: Int) -> String {
        let kilohertz = Double(hertz) / 1000
        return kilohertz == kilohertz.rounded()
            ? String(Int(kilohertz))
            : String(format: "%.1f", kilohertz)
    }

    /// Linear true peak (> 1) as a decibel string, one decimal ("0.9").
    private static func dBTP(_ linear: Double) -> String {
        String(format: "%.1f", 20 * log10(linear))
    }

    // MARK: - Data

    private func load() async {
        do {
            self.report = try await self.repository.fetchAudioQuality()
        } catch {
            self.loadFailed = true
            AppLogger.make(.ui).error(
                "librarySummary.audioQuality.load.failed",
                ["error": String(reflecting: error)]
            )
        }
    }
}

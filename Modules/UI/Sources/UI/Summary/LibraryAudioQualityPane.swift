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
    /// Observed (unlike the other panes' plain `let`) so the provenance
    /// batch progress row updates live while a run is underway.
    @ObservedObject var library: LibraryViewModel

    @State private var report: LibraryAudioQualityReport?
    @State private var loadFailed = false
    @State private var mixedExpanded = false
    @State private var oversExpanded = false
    @State private var suspectsExpanded = false

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
        .onChange(of: self.library.provenanceProgress) { _, progress in
            // Fresh verdicts change the report; reload once the batch lands.
            guard progress?.isComplete == true else { return }
            Task { await self.load() }
        }
    }

    // MARK: - Sections

    private func reportForm(_ report: LibraryAudioQualityReport) -> some View {
        Form {
            self.provenanceSection(report)
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

    /// The Transcode Detection section (ADR-075 slice 3 and ADR-075 slice 4): an always
    /// present Analyse Now trigger (or the live batch progress while a run is
    /// underway), and the suspected-transcode offender list once at least one
    /// track holds a verdict. The word is always "suspected"; the footer
    /// explains what a shelf is and why a flagged file can be innocent.
    private func provenanceSection(_ report: LibraryAudioQualityReport) -> some View {
        Section {
            if let progress = self.library.provenanceProgress {
                self.provenanceProgressRows(progress)
            } else {
                self.analyseRow(report)
            }
            if report.provenanceAnalysedCount > 0 {
                self.suspectRows(report)
            }
        } header: {
            Text(localized: "Transcode Detection")
        } footer: {
            self.provenanceFooter
        }
    }

    /// The in-place trigger. Nothing runs automatically (a first pass over a
    /// big library is hours of decoding), so the button stays put: the
    /// scanner queues new and changed files up for it by clearing their
    /// verdicts, and the button goes quiet when nothing is waiting.
    private func analyseRow(_ report: LibraryAudioQualityReport) -> some View {
        HStack {
            Text(self.analyseRowStatus(report))
            Spacer()
            Button(L10n.string("Analyse Now")) {
                self.library.startProvenanceAnalysis(announce: false)
            }
            .buttonStyle(.bordered)
            .disabled(report.provenanceUnanalysedCount == 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func analyseRowStatus(_ report: LibraryAudioQualityReport) -> String {
        if report.provenanceUnanalysedCount == 0 {
            return L10n.string("Nothing awaiting analysis")
        }
        return report.provenanceAnalysedCount == 0
            ? L10n.string("\(report.provenanceUnanalysedCount) lossless files have never been checked")
            : L10n.string("\(report.provenanceUnanalysedCount) lossless files awaiting analysis")
    }

    /// Live progress for the Tools menu's "Analyse Provenance" batch
    /// (ADR-075 slice 3), with Cancel while running and Dismiss once complete.
    @ViewBuilder
    private func provenanceProgressRows(_ progress: ProvenanceBatchProgress) -> some View {
        if progress.isComplete {
            HStack(spacing: 6) {
                // Failures must be visible right here: the completion toast
                // lands in the main window, which this pane usually covers.
                Image(systemName: progress.failed > 0
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill")
                    .foregroundStyle(progress.failed > 0 ? Color.orange : Color.green)
                Text(Self.completionRowText(progress))
            }
            Button(L10n.string("Dismiss")) {
                self.library.provenanceProgress = nil
            }
            .buttonStyle(.bordered)
        } else {
            HStack(spacing: 8) {
                ProgressView(
                    value: Double(progress.done),
                    total: Double(progress.total)
                )
                Text(verbatim: "\(progress.done) / \(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(L10n.string("Cancel")) {
                    self.library.cancelProvenanceAnalysis()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// The offenders (ADR-075 slice 4): highest confidence first, collapsed by
    /// default, each row navigating to its album. A clean run gets a plain
    /// all-clear instead of an empty disclosure group.
    @ViewBuilder
    private func suspectRows(_ report: LibraryAudioQualityReport) -> some View {
        if report.suspectedTranscodeCount == 0 {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(L10n.string("No suspected transcodes in \(report.provenanceAnalysedCount) analysed files"))
            }
        } else {
            DisclosureGroup(
                L10n.string("Suspected Transcodes (\(report.suspectedTranscodeCount))"),
                isExpanded: self.$suspectsExpanded
            ) {
                ForEach(report.suspectedTranscodes) { track in
                    SummaryOffenderRow(
                        title: track.albumTitle
                            .map { "\(track.trackTitle) · \($0)" } ?? track.trackTitle,
                        detail: Self.suspectDetail(track),
                        albumID: track.albumID,
                        library: self.library,
                        trackID: track.id
                    )
                }
                SummaryMoreRow(
                    total: report.suspectedTranscodeCount,
                    shown: report.suspectedTranscodes.count
                )
            }
        }
    }

    /// The plain-copy explanation the phase spec fixes: what a shelf is, and
    /// why a verdict can be wrong. Coverage lives in the analyse row above,
    /// which shows the awaiting count whenever anything is unanalysed.
    private var provenanceFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                localized: """
                A lossy encoder throws away everything above a frequency ceiling, and that hard \
                spectral shelf survives re-encoding to a lossless file. Old digitisations, live \
                recordings, and dull masters can show the same shelf, so a flagged file is only \
                ever suspected. Nothing is changed, moved, or deleted.
                """
            )
        }
        .font(Typography.caption)
        .foregroundStyle(Color.textTertiary)
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
                        library: self.library,
                        trackID: track.id
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

    /// "N analysed, M suspected(, K failed)": the batch outcome with its
    /// failures owned, not hidden.
    private static func completionRowText(_ progress: ProvenanceBatchProgress) -> String {
        let base = L10n.string("\(progress.succeeded) analysed, \(progress.suspected) suspected")
        return progress.failed > 0 ? L10n.string("\(base), \(progress.failed) failed") : base
    }

    /// The ADR-075 slice 4 offender detail: "87% confident · shelf at 16 kHz".
    private static func suspectDetail(_ track: LibraryAudioQualityReport.SuspectedTranscodeTrack) -> String {
        let confidence = track.confidence.formatted(.percent.precision(.fractionLength(0)))
        guard let shelfHz = track.shelfFrequencyHz else {
            return L10n.string("\(confidence) confident")
        }
        return L10n.string("\(confidence) confident · shelf at \(self.kHz(shelfHz)) kHz")
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

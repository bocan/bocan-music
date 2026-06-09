import AudioEngine
import SwiftUI

// MARK: - ReplayGainSettingsView

/// Settings UI for ReplayGain: mode picker, pre-amp, and analysis actions.
///
/// Analysis is run in a background task; the view shows progress and result via
/// `LibraryViewModel.replayGainProgress`.
public struct ReplayGainSettingsView: View {
    @Bindable var vm: DSPViewModel
    // TODO: When LibraryViewModel is migrated to @Observable, change to:
    // @Environment(LibraryViewModel.self) private var library
    // and update injection sites from .environmentObject(library) → .environment(library)
    @EnvironmentObject private var library: LibraryViewModel

    @State private var showRecomputeConfirm = false

    public init(vm: DSPViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Form {
            self.modeSection
            self.preAmpSection
            self.analysisSection
        }
        .formStyle(.grouped)
        .confirmationDialog(
            L10n.string("Recompute ReplayGain for all tracks?"),
            isPresented: self.$showRecomputeConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Recompute All"), role: .destructive) {
                Task { await self.library.recomputeAllReplayGain() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(localized: "This will re-analyse every track in the library. It may take several minutes.")
        }
    }

    // MARK: - Sections

    private var modeSection: some View {
        Section(L10n.string("Playback Mode")) {
            Picker(L10n.string("ReplayGain"), selection: self.$vm.state.replayGainMode) {
                Text(localized: "Off").tag(ReplayGainMode.off)
                Text(localized: "Track Gain").tag(ReplayGainMode.track)
                Text(localized: "Album Gain").tag(ReplayGainMode.album)
                Text(localized: "Auto").tag(ReplayGainMode.auto)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(L10n.string("ReplayGain mode"))
            .help(L10n.string(
                "Off: none. Track: −18 LUFS. Album: preserves relative dynamics. Auto: album gain within albums, track gain otherwise."
            ))
            Text(self.modeHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var preAmpSection: some View {
        Section(L10n.string("Pre-Amplifier")) {
            LabeledContent(L10n.string("Pre-amp")) {
                HStack {
                    Slider(value: self.$vm.state.preAmpDB, in: -12 ... 12, step: 0.5)
                        .accessibilityLabel(L10n.string("ReplayGain pre-amplifier"))
                        .help(L10n.string(
                            "Extra gain on top of the ReplayGain value. A clipping guard prevents the peak from exceeding −0.5 dBFS."
                        ))
                    Text(String(format: "%+.1f dB", self.vm.state.preAmpDB))
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
            }
            Text(localized:
                "Applied on top of the resolved ReplayGain value. A clipping guard prevents the output peak from exceeding −0.5 dBFS.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var analysisSection: some View {
        Section(L10n.string("Analysis")) {
            if let progress = self.library.replayGainProgress {
                self.progressRow(progress)
            } else {
                self.analysisButtons
            }
        }
    }

    private var analysisButtons: some View {
        Group {
            HStack {
                Text(localized: "Compute missing ReplayGain values")
                Spacer()
                Button(L10n.string("Compute Missing")) {
                    Task { await self.library.computeMissingReplayGain() }
                }
                .buttonStyle(.bordered)
                .help(L10n.string("Analyse any tracks that don't yet have ReplayGain data"))
            }
            .accessibilityElement(children: .combine)

            Button(L10n.string("Recompute All…"), role: .destructive) {
                self.showRecomputeConfirm = true
            }
            .accessibilityLabel(L10n.string("Recompute ReplayGain for all library tracks"))
            .help(L10n.string("Re-analyse every track in the library. This may take several minutes."))
        }
    }

    private func progressRow(_ progress: ReplayGainBatchProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.isComplete {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(self.completionMessage(progress))
                        .font(.callout)
                }
                Button(L10n.string("Dismiss")) { self.library.replayGainProgress = nil }
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
                        .frame(width: 60, alignment: .trailing)
                }
                Text(localized: "Analysing\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Labels

    private func completionMessage(_ progress: ReplayGainBatchProgress) -> String {
        let base = L10n.string("Analysis complete — \(progress.succeeded) tracks analysed")
        return progress.failed > 0 ? L10n.string("\(base), \(progress.failed) failed") : base
    }

    private var modeHelp: String {
        switch self.vm.state.replayGainMode {
        case .off:
            L10n.string("No loudness normalisation applied.")

        case .track:
            L10n.string("Each track is normalised individually to −18 LUFS.")

        case .album:
            L10n.string("The whole album is normalised together, preserving relative dynamics between tracks.")

        case .auto:
            L10n.string("Album gain when playing a complete album; track gain otherwise.")
        }
    }
}

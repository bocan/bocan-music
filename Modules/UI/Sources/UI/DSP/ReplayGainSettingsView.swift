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
            "Recompute ReplayGain for all tracks?",
            isPresented: self.$showRecomputeConfirm,
            titleVisibility: .visible
        ) {
            Button("Recompute All", role: .destructive) {
                Task { await self.library.recomputeAllReplayGain() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will re-analyse every track in the library. It may take several minutes.")
        }
    }

    // MARK: - Sections

    private var modeSection: some View {
        Section("Playback Mode") {
            Picker("ReplayGain", selection: self.$vm.state.replayGainMode) {
                Text("Off").tag(ReplayGainMode.off)
                Text("Track Gain").tag(ReplayGainMode.track)
                Text("Album Gain").tag(ReplayGainMode.album)
                Text("Auto").tag(ReplayGainMode.auto)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("ReplayGain mode")
            .help("Off: none. Track: −18 LUFS. Album: preserves relative dynamics. Auto: album gain within albums, track gain otherwise.")
            Text(self.modeHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var preAmpSection: some View {
        Section("Pre-Amplifier") {
            LabeledContent("Pre-amp") {
                HStack {
                    Slider(value: self.$vm.state.preAmpDB, in: -12 ... 12, step: 0.5)
                        .accessibilityLabel("ReplayGain pre-amplifier")
                        .help("Extra gain on top of the ReplayGain value. A clipping guard prevents the peak from exceeding −0.5 dBFS.")
                    Text(String(format: "%+.1f dB", self.vm.state.preAmpDB))
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
            }
            Text("Applied on top of the resolved ReplayGain value. A clipping guard prevents the output peak from exceeding −0.5 dBFS.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var analysisSection: some View {
        Section("Analysis") {
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
                Text("Compute missing ReplayGain values")
                Spacer()
                Button("Compute Missing") {
                    Task { await self.library.computeMissingReplayGain() }
                }
                .buttonStyle(.bordered)
                .help("Analyse any tracks that don't yet have ReplayGain data")
            }
            .accessibilityElement(children: .combine)

            Button("Recompute All…", role: .destructive) {
                self.showRecomputeConfirm = true
            }
            .accessibilityLabel("Recompute ReplayGain for all library tracks")
            .help("Re-analyse every track in the library. This may take several minutes.")
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
                Button("Dismiss") { self.library.replayGainProgress = nil }
                    .buttonStyle(.bordered)
            } else {
                HStack(spacing: 8) {
                    ProgressView(
                        value: Double(progress.done),
                        total: Double(progress.total)
                    )
                    Text("\(progress.done) / \(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                Text("Analysing\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Labels

    private func completionMessage(_ progress: ReplayGainBatchProgress) -> String {
        let noun = progress.succeeded == 1 ? "track" : "tracks"
        let base = "Analysis complete — \(progress.succeeded) \(noun) analysed"
        return progress.failed > 0 ? "\(base), \(progress.failed) failed" : base
    }

    private var modeHelp: String {
        switch self.vm.state.replayGainMode {
        case .off:
            "No loudness normalisation applied."

        case .track:
            "Each track is normalised individually to −18 LUFS."

        case .album:
            "The whole album is normalised together, preserving relative dynamics between tracks."

        case .auto:
            "Album gain when playing a complete album; track gain otherwise."
        }
    }
}

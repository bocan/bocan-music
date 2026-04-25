import AudioEngine
import SwiftUI

// MARK: - ReplayGainSettingsView

/// Settings UI for ReplayGain: mode picker, pre-amp, and analysis actions.
///
/// Analysis is run in a background task; the view shows progress and result via
/// `DSPViewModel.isAnalyzing`.
public struct ReplayGainSettingsView: View {
    @ObservedObject var vm: DSPViewModel

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
                // TODO(phase-10): trigger full-library ReplayGain recomputation
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
            HStack {
                Text(self.vm.isAnalyzing ? "Analysing…" : "Compute missing ReplayGain values")
                Spacer()
                if self.vm.isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Compute Missing") {
                        // TODO(phase-10): trigger compute-missing operation
                    }
                    .buttonStyle(.bordered)
                }
            }
            .accessibilityElement(children: .combine)

            Button("Recompute All…", role: .destructive) {
                self.showRecomputeConfirm = true
            }
            .accessibilityLabel("Recompute ReplayGain for all library tracks")
        }
    }

    // MARK: - Labels

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

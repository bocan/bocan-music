import AudioEngine
import SwiftUI

// MARK: - DSPView

/// Controls for bass boost, crossfeed, stereo width, and crossfade transitions.
///
/// Displayed as a settings panel; composable into a sheet or sidebar pane.
public struct DSPView: View {
    @ObservedObject var vm: DSPViewModel

    public init(vm: DSPViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Form {
            self.bassBoostSection
            self.crossfeedSection
            self.stereoSection
            self.transitionSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Bass boost

    private var bassBoostSection: some View {
        Section("Bass Boost") {
            LabeledContent("Gain") {
                HStack {
                    Slider(value: self.$vm.state.bassBoostDB, in: 0 ... 12, step: 0.5)
                        .accessibilityLabel("Bass boost gain")
                        .help("Low-shelf boost at 80 Hz. 0 = off; 12 = maximum bass enhancement.")
                    Text(String(format: "%.1f dB", self.vm.state.bassBoostDB))
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }
            }
            Text("Low-shelf filter at 80 Hz. 0 = off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Crossfeed

    private var crossfeedSection: some View {
        Section("Headphone Crossfeed") {
            LabeledContent("Amount") {
                HStack {
                    Slider(value: self.$vm.state.crossfeedAmount, in: 0 ... 1, step: 0.05)
                        .accessibilityLabel("Crossfeed amount")
                        .help("Bauer crossfeed level. 0 = off; 100% = full binaural matrix (≈−9.5 dB cross-talk). Best for headphones.")
                    Text(String(format: "%.0f%%", self.vm.state.crossfeedAmount * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
            }
            Text("Bauer stereo-to-binaural matrix. Reduces stereo fatigue on headphones. 0 = off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Stereo expander

    private var stereoSection: some View {
        Section("Stereo Width") {
            LabeledContent("Width") {
                HStack {
                    Slider(value: self.$vm.state.stereoWidth, in: 0.5 ... 2.0, step: 0.05)
                        .accessibilityLabel("Stereo width")
                        .help("Mid/side width multiplier. 1.0 = original; below 1 narrows toward mono; above 1 widens the stereo field.")
                    Text(self.widthLabel)
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }
            }
            Text("Mid/side matrix. 1.0 = original. 0.5 = narrower. 2.0 = wider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Crossfade / transitions

    private var transitionSection: some View {
        Section("Transitions") {
            LabeledContent("Crossfade") {
                HStack {
                    Slider(
                        value: self.$vm.state.crossfadeSeconds,
                        in: 0 ... 10,
                        step: 0.5
                    )
                    .accessibilityLabel("Crossfade duration")
                    .help("Duration of the crossfade between tracks. 0 = sample-accurate gapless playback.")
                    Text(self.crossfadeLabel)
                        .font(.caption.monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                }
            }

            if self.vm.state.crossfadeSeconds > 0 {
                Toggle(
                    "Keep gapless within albums",
                    isOn: self.$vm.state.crossfadeAlbumGapless
                )
                .accessibilityLabel("Keep gapless playback within albums when crossfade is active")
                .help("When on, consecutive album tracks stay gapless; crossfade only applies at album boundaries.")
            }

            Text(self.transitionHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Labels

    private var widthLabel: String {
        let width = self.vm.state.stereoWidth
        if abs(width - 1.0) < 0.01 { return "1.0× (off)" }
        return String(format: "%.2f×", width)
    }

    private var crossfadeLabel: String {
        let seconds = self.vm.state.crossfadeSeconds
        if seconds == 0 { return "0 (Gapless)" }
        return String(format: "%.1f s", seconds)
    }

    private var transitionHelp: String {
        if self.vm.state.crossfadeSeconds == 0 {
            return "0 s = sample-accurate gapless (Phase 5 path)."
        }
        if self.vm.state.crossfadeAlbumGapless {
            return "Within-album boundaries use gapless; cross-album boundaries use crossfade."
        }
        return "Crossfade applies at every track boundary."
    }
}

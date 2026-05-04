import AudioEngine
import SwiftUI

// MARK: - EQView

/// 10-band parametric EQ with preset picker, bypass toggle, and A/B compare.
///
/// Sliders are vertical, labelled with ISO centre-frequency names.
/// The A/B button is press-and-hold: the flat reference is active only while
/// the button is held down, returning to the active preset on release.
public struct EQView: View {
    @Bindable var vm: DSPViewModel

    /// Tracks whether A/B compare mode is showing the flat reference.
    @State private var isABFlat = false
    /// Saved gains before A/B compare switch.
    @State private var savedPresetID: EQPreset.ID?
    @State private var showSaveSheet = false
    @State private var savePresetName = ""
    @State private var showManagePresets = false

    private var currentPreset: EQPreset? {
        guard let id = vm.state.eqPresetID else { return nil }
        return self.vm.presets.first { $0.id == id }
    }

    public init(vm: DSPViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 12) {
            self.topBar
            self.scopeRow
            Divider()
            self.bandSliders
            Divider()
            self.outputGainRow
        }
        .padding()
        .sheet(isPresented: self.$showSaveSheet) { self.saveSheet }
        .sheet(isPresented: self.$showManagePresets) {
            PresetManagerView(vm: self.vm)
        }
    }

    // MARK: - Scope row

    private var scopeRow: some View {
        HStack(spacing: 8) {
            Text("Scope:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("EQ Scope", selection: self.$vm.eqScope) {
                ForEach(EQScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("EQ scope: Global, This Album, or This Track")
            .help("Select which scope the EQ preset applies to")
            .fixedSize()
            .disabled(
                (self.vm.eqScope == .track || self.vm.currentTrackID == nil) &&
                    (self.vm.eqScope == .album || self.vm.currentAlbumID == nil) &&
                    false
            )

            Spacer()

            if self.vm.eqScope != .global {
                if self.vm.hasScopedPreset {
                    Button("Clear Override") {
                        Task { await self.vm.clearCurrentScopePreset() }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .accessibilityLabel(
                        "Clear \(self.vm.eqScope.rawValue.lowercased()) EQ override"
                    )
                    .help("Remove the EQ preset override for \(self.vm.eqScope.rawValue.lowercased())")
                }
                let scopeName = self.vm.eqScope == .track ? "track" : "album"
                let hasContext = self.vm.eqScope == .track
                    ? self.vm.currentTrackID != nil
                    : self.vm.currentAlbumID != nil
                Button("Save for \(self.vm.eqScope.rawValue)") {
                    Task { await self.vm.saveCurrentScopePreset() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(!hasContext || self.vm.state.eqPresetID == nil)
                .accessibilityLabel("Save current preset for \(self.vm.eqScope.rawValue.lowercased())")
                .help(
                    "Pin the current EQ preset to this \(scopeName). " +
                        "It will be applied automatically when this \(scopeName) plays."
                )
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Toggle("EQ", isOn: self.$vm.state.eqEnabled)
                .accessibilityLabel("Enable equaliser")
                .toggleStyle(.switch)
                .help("Enable or bypass the 10-band equaliser")

            Spacer()

            self.presetPicker

            self.abButton
        }
    }

    private var presetPicker: some View {
        Menu {
            ForEach(BuiltInPresets.all) { preset in
                Button(preset.name) { self.vm.selectPreset(preset) }
            }
            if self.vm.presets.contains(where: { !$0.isBuiltIn }) {
                Divider()
                ForEach(self.vm.presets.filter { !$0.isBuiltIn }) { preset in
                    Button(preset.name) { self.vm.selectPreset(preset) }
                }
            }
            Divider()
            Button("Save as Preset…") { self.showSaveSheet = true }
            Button("Manage Presets…") { self.showManagePresets = true }
        } label: {
            Label(self.currentPreset?.name ?? "Custom", systemImage: "music.note.list")
                .accessibilityLabel("EQ preset: \(self.currentPreset?.name ?? "Custom")")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Select a built-in or saved EQ preset")
    }

    private var abButton: some View {
        Text(self.isABFlat ? "B" : "A")
            .monospacedDigit()
            .frame(width: 28, height: 28)
            .background(self.isABFlat ? Color.accentColor : Color.secondary.opacity(0.2))
            .foregroundStyle(self.isABFlat ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Press-and-hold: flat reference is active only while finger/mouse is down.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !self.isABFlat else { return }
                        self.savedPresetID = self.vm.state.eqPresetID
                        self.vm.state.eqPresetID = BuiltInPresets.flat.id
                        self.isABFlat = true
                    }
                    .onEnded { _ in
                        guard self.isABFlat else { return }
                        self.vm.state.eqPresetID = self.savedPresetID
                        self.isABFlat = false
                    }
            )
            .accessibilityLabel("A/B compare: hold for flat reference")
            .accessibilityHint("Hold to preview flat EQ; release to return to active preset")
            .help("Hold for flat reference — release to return to active preset")
            .contentShape(Rectangle())
    }

    // MARK: - Band sliders

    private var bandSliders: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(EQUnit.isoFrequencies.enumerated()), id: \.offset) { index, freq in
                BandSliderView(
                    label: self.freqLabel(freq),
                    gain: self.bandGainBinding(for: index),
                    isEnabled: self.vm.state.eqEnabled
                )
            }
        }
        .frame(height: 200)
    }

    private var outputGainRow: some View {
        HStack {
            Text("Output")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: self.outputGainBinding,
                in: -12 ... 12,
                step: 0.5
            )
            .accessibilityLabel("EQ output gain")
            .accessibilityValue(String(format: "%+.1f dB", self.outputGainValue))
            .help("Output trim after EQ — compensate for loudness change introduced by the curve")
            Text(String(format: "%+.1f dB", self.outputGainValue))
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
    }

    // MARK: - Save sheet

    private var saveSheet: some View {
        VStack(spacing: 16) {
            Text("Save EQ Preset")
                .font(.headline)
            TextField("Preset name", text: self.$savePresetName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { self.showSaveSheet = false }
                Spacer()
                Button("Save") {
                    self.vm.saveUserPreset(name: self.savePresetName)
                    self.savePresetName = ""
                    self.showSaveSheet = false
                }
                .disabled(self.savePresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 280)
    }

    // MARK: - Helpers

    private func bandGainBinding(for index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let id = vm.state.eqPresetID,
                      let preset = vm.presets.first(where: { $0.id == id }),
                      index < preset.bandGainsDB.count else { return 0 }
                return preset.bandGainsDB[index]
            },
            set: { newValue in
                // Create a custom preset with the updated band
                self.applyBandChange(index: index, gain: newValue)
            }
        )
    }

    private var outputGainValue: Double {
        guard let id = vm.state.eqPresetID,
              let preset = vm.presets.first(where: { $0.id == id }) else { return 0 }
        return preset.outputGainDB
    }

    private var outputGainBinding: Binding<Double> {
        Binding(
            get: { self.outputGainValue },
            set: { self.vm.updateOutputGain($0) }
        )
    }

    private func applyBandChange(index: Int, gain: Double) {
        self.vm.updateBandGain(index: index, gain: gain)
    }

    private func freqLabel(_ freq: Float) -> String {
        if freq >= 1000 {
            return String(format: "%.0fk", freq / 1000)
        }
        return String(format: "%.0f", freq)
    }
}

// MARK: - BandSliderView

private struct BandSliderView: View {
    let label: String
    @Binding var gain: Double
    let isEnabled: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%+.0f", self.gain))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
            // Pre-size to 140 wide so the track gets full travel, then rotate to
            // make it vertical; constrain the layout frame to 28×140 after rotation.
            Slider(value: self.$gain, in: -12 ... 12, step: 0.5)
                .frame(width: 140)
                .rotationEffect(.degrees(-90))
                .frame(width: 28, height: 140)
                .disabled(!self.isEnabled)
                .help("\(self.label) Hz band: ±12 dB")
                .accessibilityLabel("\(self.label) Hz EQ band")
                .accessibilityValue(String(format: "%+.0f dB", self.gain))
            Text(self.label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}

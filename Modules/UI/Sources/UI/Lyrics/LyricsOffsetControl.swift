import SwiftUI

// MARK: - LyricsOffsetControl

/// A compact button that opens a popover for adjusting the lyrics sync offset
/// (−5 000 ms to +5 000 ms in 50 ms steps). Shared by the lyrics pane and the
/// Immersive Mode lyrics column (ADR-089), so both surfaces present one
/// control with one identifier. Only meaningful for a synced document; the
/// caller decides whether to show it.
///
/// The offset is live while the popover is open and committed to the track
/// when it closes, matching ``LyricsViewModel/commitOffset()``.
struct LyricsOffsetControl: View {
    @ObservedObject var vm: LyricsViewModel

    @State private var showPopover = false

    var body: some View {
        Button {
            self.showPopover.toggle()
        } label: {
            Image(systemName: "timer")
                .symbolVariant(self.vm.userOffsetMS != 0 ? .fill : .none)
                .foregroundStyle(self.vm.userOffsetMS != 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .help(self.vm.userOffsetMS == 0
            ? L10n.string("Adjust sync offset")
            : L10n.string("Sync offset: \(self.vm.userOffsetMS > 0 ? "+" : "")\(self.vm.userOffsetMS) ms"))
        .accessibilityLabel(L10n.string("Adjust lyrics sync offset"))
        .accessibilityIdentifier(A11y.Lyrics.offsetButton)
        .popover(isPresented: self.$showPopover, arrowEdge: .bottom) {
            self.popover
        }
        .onChange(of: self.showPopover) { _, shown in
            if !shown { self.vm.commitOffset() }
        }
    }

    private var popover: some View {
        let offsetBinding = Binding<Double>(
            get: { Double(self.vm.userOffsetMS) },
            set: { self.vm.userOffsetMS = Int($0.rounded()) }
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text(localized: "Sync Offset")
                .font(.headline)

            Slider(value: offsetBinding, in: -5000 ... 5000, step: 50) {
                Text(localized: "Offset")
            }
            .accessibilityIdentifier(A11y.Lyrics.offsetSlider)
            .accessibilityValue(self.valueLabel)
            .frame(width: 220)

            HStack {
                Text(verbatim: self.valueLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Button(L10n.string("Reset")) {
                    self.vm.userOffsetMS = 0
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.vm.userOffsetMS == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .disabled(self.vm.userOffsetMS == 0)
            }

            Text(localized: "Shifts highlighted line timing.\nResets when the track changes.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 260)
    }

    /// Signed millisecond readout shown under the slider and announced as the
    /// slider's accessibility value (so VoiceOver reads "+250 ms", not a percentage).
    private var valueLabel: String {
        self.vm.userOffsetMS == 0
            ? "0 ms"
            : "\(self.vm.userOffsetMS > 0 ? "+" : "")\(self.vm.userOffsetMS) ms"
    }
}

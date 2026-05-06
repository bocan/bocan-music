import SwiftUI

// MARK: - SpeedPickerView

/// A popover-backed speed control shown in the NowPlayingStrip.
///
/// Tapping the "1.0×" label opens a popover with a slider (0.5×–2.0×) and
/// quick-pick buttons.  Hidden at 1.0× by default; visible on hover or when
/// a non-unity rate is set.
public struct SpeedPickerView: View {
    public var vm: NowPlayingViewModel
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"
    @State private var isPopoverShown = false
    @State private var isHovered = false
    /// Held locally during a drag; setRate is called only once on release so the
    /// spectral time-pitch node isn't hammered on every mouse-move event.
    @State private var dragRate: Double?

    public init(vm: NowPlayingViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Button {
            self.isPopoverShown.toggle()
        } label: {
            Text(self.rateLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(self.labelColor)
                .frame(width: 36)
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .help("Playback speed")
        .accessibilityLabel("Speed: \(self.rateLabel)")
        .accessibilityIdentifier(A11y.NowPlaying.speedPicker)
        .popover(isPresented: self.$isPopoverShown, arrowEdge: .top) {
            self.popoverContent
        }
    }

    // MARK: - Popover

    private var popoverContent: some View {
        VStack(spacing: 12) {
            Text("Playback Speed")
                .font(.headline)

            Text(self.rateLabel)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(AccentPalette.color(for: self.accentColorKey))

            Slider(
                value: Binding(
                    get: { self.dragRate ?? Double(self.vm.playbackRate) },
                    set: { self.dragRate = $0 }
                ),
                in: 0.5 ... 2.0,
                step: 0.05
            ) { editing in
                if !editing, let rate = self.dragRate {
                    self.dragRate = nil
                    Task { await self.vm.setRate(Float(rate)) }
                }
            }
            .frame(width: 200)
            .accessibilityLabel("Speed slider")

            HStack(spacing: 8) {
                ForEach(Self.quickRates, id: \.self) { rate in
                    Button(String(format: "%.2g×", rate)) {
                        Task { await self.vm.setRate(rate) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(abs(self.vm.playbackRate - rate) < 0.01 ? Color.accentColor : nil)
                }
            }

            Button("Reset to 1×") {
                Task { await self.vm.setRate(1.0) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textSecondary)
            .font(.footnote)
        }
        .padding(16)
        .frame(width: 240)
    }

    // MARK: - Helpers

    private static let quickRates: [Float] = NowPlayingViewModel.quickRates

    private var rateLabel: String {
        String(format: "%.2g×", self.vm.playbackRate)
    }

    private var isActive: Bool {
        abs(self.vm.playbackRate - 1.0) > 0.01
    }

    /// Foreground colour for the rate label.
    ///
    /// - Active (non-unity rate): accent colour — draws the eye.
    /// - Hovered at unity: `textPrimary` — indicates interactivity.
    /// - Idle at unity: `textTertiary` — de-emphasised but WCAG AA compliant,
    ///   matching the convention used by shuffle/repeat/sleep inactive states.
    private var labelColor: Color {
        if self.isActive { return AccentPalette.color(for: self.accentColorKey) }
        return self.isHovered ? Color.textPrimary : Color.textTertiary
    }
}

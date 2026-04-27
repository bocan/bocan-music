import SwiftUI

// MARK: - SpeedPickerView

/// A popover-backed speed control shown in the NowPlayingStrip.
///
/// Tapping the "1.0×" label opens a popover with a slider (0.5×–2.0×) and
/// quick-pick buttons.  Hidden at 1.0× by default; visible on hover or when
/// a non-unity rate is set.
public struct SpeedPickerView: View {
    @ObservedObject public var vm: NowPlayingViewModel
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
                .foregroundStyle(self.isActive ? AccentPalette.color(for: self.accentColorKey) : Color.textPrimary)
                .frame(width: 36)
        }
        .buttonStyle(.plain)
        .opacity(self.isActive || self.isHovered ? 1 : 0.4)
        .onHover { self.isHovered = $0 }
        .help("Playback speed")
        .accessibilityLabel("Speed: \(self.rateLabel)")
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

    private static let quickRates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    private var rateLabel: String {
        String(format: "%.2g×", self.vm.playbackRate)
    }

    private var isActive: Bool {
        abs(self.vm.playbackRate - 1.0) > 0.01
    }
}

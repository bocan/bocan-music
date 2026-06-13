import SwiftUI

// MARK: - VisualizerControlOverlay

/// Translucent right-side overlay with two steppers: one cycles the visualizer
/// mode, the other the colour palette. It mirrors ``NowPlayingOverlay`` on the
/// left: it fades out after `fadeAfter` seconds and reappears whenever
/// `refreshTrigger` changes (pointer movement over the visualizer). While the
/// pointer is directly over the control it stays put, so the steppers are usable
/// without racing the fade, and it is non-interactive while hidden so a hover
/// over the (invisible) corner cannot trip a stepper.
struct VisualizerControlOverlay: View {
    @ObservedObject var vm: VisualizerViewModel
    /// Reduce motion gates the Metal-only Nebula mode out of the cycle (the host
    /// substitutes Spectrum Bars for it there).
    let reduceMotion: Bool
    /// Tighter spacing and smaller glyphs for the mini player's small square.
    var compact = false
    var fadeAfter: TimeInterval = 3
    /// Increment from the parent (on hover) to reappear and restart the timer.
    var refreshTrigger = 0

    @State private var isVisible = true
    @State private var isPointerInside = false
    @State private var fadeTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .center, spacing: self.compact ? 4 : 8) {
            self.stepperRow(Stepper(
                label: self.vm.mode.displayName,
                accessibility: L10n.string("Visualizer mode"),
                previousHelp: L10n.string("Previous visualizer"),
                nextHelp: L10n.string("Next visualizer")
            ) { self.cycleMode(by: $0) })
            self.stepperRow(Stepper(
                label: self.vm.palette.displayName,
                accessibility: L10n.string("Colour Palette"),
                previousHelp: L10n.string("Previous palette"),
                nextHelp: L10n.string("Next palette")
            ) { self.cyclePalette(by: $0) })
        }
        .padding(.horizontal, self.compact ? 8 : 12)
        .padding(.vertical, self.compact ? 6 : 10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(
                self.reduceTransparency
                    ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                    : AnyShapeStyle(Material.ultraThin)
            )
        )
        .padding(12)
        .opacity(self.isVisible ? 1 : 0)
        .allowsHitTesting(self.isVisible)
        .animation(.easeOut(duration: 0.5), value: self.isVisible)
        .onAppear { self.scheduleHide() }
        .onChange(of: self.refreshTrigger) { _, _ in self.reshowAndSchedule() }
        .onHover { hovering in
            self.isPointerInside = hovering
            if hovering {
                self.isVisible = true
                self.fadeTask?.cancel()
            } else {
                self.scheduleHide()
            }
        }
    }

    // MARK: - Stepper row

    /// One stepper row's content. `onStep` takes -1 for previous and +1 for next.
    private struct Stepper {
        let label: String
        let accessibility: String
        let previousHelp: String
        let nextHelp: String
        let onStep: (Int) -> Void
    }

    private func stepperRow(_ stepper: Stepper) -> some View {
        HStack(spacing: self.compact ? 3 : 4) {
            self.arrowButton(systemName: "chevron.left", help: stepper.previousHelp) { stepper.onStep(-1) }
            Text(stepper.label)
                .font(self.compact ? .caption : .subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // A small floor keeps short names from making the box jump around
                // as they are cycled; long names grow it. The arrows hug the name.
                .frame(minWidth: self.compact ? 48 : 60)
                .multilineTextAlignment(.center)
            self.arrowButton(systemName: "chevron.right", help: stepper.nextHelp) { stepper.onStep(1) }
        }
        // One adjustable element for VoiceOver: swipe up/down maps to next/previous,
        // which is the idiomatic stepper gesture; the visible chevrons serve the mouse.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stepper.accessibility)
        .accessibilityValue(stepper.label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                stepper.onStep(1)

            case .decrement:
                stepper.onStep(-1)

            @unknown default:
                break
            }
        }
    }

    private func arrowButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: self.compact ? 10 : 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: self.compact ? 20 : 24, height: self.compact ? 20 : 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Cycling

    private func cycleMode(by delta: Int) {
        let modes = VisualizerViewModel.availableModes(
            reduceMotion: self.reduceMotion,
            hasMetalDevice: MetalSupport.device != nil
        )
        self.vm.mode = VisualizerViewModel.cycled(self.vm.mode, in: modes, by: delta)
        self.reshowAndSchedule()
    }

    private func cyclePalette(by delta: Int) {
        self.vm.palette = VisualizerViewModel.cycled(self.vm.palette, in: VisualizerPalette.allCases, by: delta)
        self.reshowAndSchedule()
    }

    // MARK: - Fade timer

    private func scheduleHide() {
        self.fadeTask?.cancel()
        guard !self.isPointerInside else { return }
        self.fadeTask = Task {
            try? await Task.sleep(for: .seconds(self.fadeAfter))
            guard !Task.isCancelled else { return }
            self.isVisible = false
        }
    }

    private func reshowAndSchedule() {
        self.isVisible = true
        self.scheduleHide()
    }
}

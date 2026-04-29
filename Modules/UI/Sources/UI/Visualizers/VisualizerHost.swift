import AudioEngine
import SwiftUI

// MARK: - VisualizerHost

/// Container view that drives the active visualizer mode at display rate.
///
/// - Uses `TimelineView(.animation(minimumInterval:))` to clock Canvas redraws.
///   Canvas content is a stateless draw call into the appropriate ``Visualizer``.
/// - The Metal-based `FluidMetal` mode drives its own `MTKView` via `CVDisplayLink`
///   inside ``FluidMetalView`` — `TimelineView` still ticks to update analysis state
///   but the GPU draw happens independently.
/// - Respects `reduceMotion`: Fluid mode is replaced by Spectrum Bars; Oscilloscope
///   pauses on the last rendered frame.
public struct VisualizerHost: View {
    // MARK: - Dependencies

    @ObservedObject public var vm: VisualizerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // MARK: - Local state

    /// Active renderer instance. Rebuilt only when mode, palette, or a11y changes.
    @State private var renderer: (any Visualizer)?
    @State private var rendererKey = ""

    // MARK: - Init

    public init(vm: VisualizerViewModel) {
        self.vm = vm
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if self.vm.mode == .fluidMetal, let fluid = renderer as? FluidMetal {
                // Metal mode: MTKView drives GPU; TimelineView updates analysis.
                FluidMetalView(renderer: fluid)
                    .ignoresSafeArea()
                    .overlay {
                        self.timelineOverlay
                    }
            } else {
                self.timelineCanvas
            }
        }
        .accessibilityLabel(self.accessibilityLabel)
        .onAppear { self.rebuildRenderer() }
        .onChange(of: self.vm.mode) { _, _ in self.rebuildRenderer() }
        .onChange(of: self.vm.palette) { _, _ in self.rebuildRenderer() }
        .onChange(of: self.reduceMotion) { _, _ in self.rebuildRenderer() }
        .onChange(of: self.reduceTransparency) { _, _ in self.rebuildRenderer() }
    }

    // MARK: - Canvas (non-Metal modes)

    @ViewBuilder
    private var timelineCanvas: some View {
        let interval = 1.0 / Double(self.vm.effectiveFPS)
        TimelineView(.animation(minimumInterval: interval, paused: false)) { _ in
            Canvas { context, size in
                guard let r = renderer else { return }
                var ctx = context
                r.render(into: &ctx, size: size, samples: self.latestSamples, analysis: self.vm.analysis)
            }
            .drawingGroup()
        }
    }

    /// For Metal mode: a zero-size TimelineView that just pumps `analysis` updates.
    @ViewBuilder
    private var timelineOverlay: some View {
        let interval = 1.0 / Double(self.vm.effectiveFPS)
        TimelineView(.animation(minimumInterval: interval, paused: false)) { _ in
            Color.clear.frame(width: 0, height: 0)
        }
    }

    // MARK: - Renderer management

    private func rebuildRenderer() {
        let key = "\(vm.mode.rawValue)-\(self.vm.palette.rawValue)-\(self.reduceMotion)-\(self.reduceTransparency)"
        guard key != self.rendererKey else { return }
        self.rendererKey = key

        let effectiveMode: VisualizerMode = self.reduceMotion && self.vm.mode.isMetalBased
            ? .spectrumBars
            : self.vm.mode

        switch effectiveMode {
        case .spectrumBars:
            self.renderer = SpectrumBars(palette: self.vm.palette, reduceMotion: self.reduceMotion)

        case .oscilloscope:
            self.renderer = Oscilloscope(palette: self.vm.palette, reduceMotion: self.reduceMotion)

        case .fluidMetal:
            self.renderer = FluidMetal(
                palette: self.vm.palette,
                reduceMotion: self.reduceMotion,
                reduceTransparency: self.reduceTransparency
            )
        }
    }

    // MARK: - Helpers

    /// The most recent audio samples — used by Canvas rendering.
    /// Falls back to a silent buffer when the tap hasn't delivered a frame yet.
    private var latestSamples: AudioSamples {
        self.vm.latestSamples ?? AudioSamples(
            timeStamp: .init(),
            sampleRate: 44100,
            mono: [],
            left: [],
            right: [],
            rms: 0,
            peak: 0
        )
    }

    private var accessibilityLabel: String {
        "Visualizer: \(self.vm.mode.displayName)"
    }
}

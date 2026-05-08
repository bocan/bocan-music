import AudioEngine
import SwiftUI

// MARK: - VisualizerHost

/// Container view that drives the active visualizer mode at display rate.
///
/// Uses `TimelineView(.animation(minimumInterval:))` to clock Canvas redraws.
/// Canvas content is a stateless draw call into the appropriate ``Visualizer``.
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
            self.timelineCanvas
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

    // MARK: - Renderer management

    private func rebuildRenderer() {
        let key = "\(vm.mode.rawValue)-\(self.vm.palette.rawValue)-\(self.reduceMotion)-\(self.reduceTransparency)"
        guard key != self.rendererKey else { return }
        self.rendererKey = key

        switch self.vm.mode {
        case .spectrumBars:
            self.renderer = SpectrumBars(palette: self.vm.palette, reduceMotion: self.reduceMotion)

        case .oscilloscope:
            self.renderer = Oscilloscope(palette: self.vm.palette, reduceMotion: self.reduceMotion)
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

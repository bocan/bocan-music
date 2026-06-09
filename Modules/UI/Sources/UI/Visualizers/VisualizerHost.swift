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

    // MARK: - Frame-rate monitoring

    @State private var lastTickDate: Date?
    @State private var slowFrameAccum: TimeInterval = 0
    @State private var hasAutoSimplified = false

    // MARK: - Init

    public init(vm: VisualizerViewModel) {
        self.vm = vm
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            Color.black
            self.timelineCanvas
        }
        .overlay(alignment: .bottom) {
            if let toast = self.vm.performanceToast {
                self.performanceToastBanner(toast: toast)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.25), value: self.vm.performanceToast?.id)
        .accessibilityLabel(self.accessibilityLabel)
        .onAppear { self.rebuildRenderer() }
        .onChange(of: self.vm.mode) { _, _ in
            self.rebuildRenderer()
            // Reset FPS monitor so a manual mode change (or revert) gets a
            // fresh 3-second window before another auto-simplify can fire.
            self.slowFrameAccum = 0
            self.hasAutoSimplified = false
        }
        .onChange(of: self.vm.palette) { _, _ in self.rebuildRenderer() }
        .onChange(of: self.reduceMotion) { _, _ in self.rebuildRenderer() }
        .onChange(of: self.reduceTransparency) { _, _ in self.rebuildRenderer() }
    }

    // MARK: - Canvas (non-Metal modes)

    @ViewBuilder
    private var timelineCanvas: some View {
        let interval = 1.0 / Double(self.vm.effectiveFPS)
        TimelineView(.animation(minimumInterval: interval, paused: false)) { tl in
            Canvas { context, size in
                guard let r = renderer else { return }
                var ctx = context
                r.render(into: &ctx, size: size, samples: self.latestSamples, analysis: self.vm.analysis)
            }
            .drawingGroup()
            .onChange(of: tl.date) { _, newDate in
                self.recordFrameTick(at: newDate)
            }
        }
    }

    // MARK: - Frame-rate monitoring

    /// Records a frame tick and triggers ``VisualizerViewModel/autoSimplify()``
    /// when the rolling average FPS stays below 30 for ≥ 3 consecutive seconds.
    private func recordFrameTick(at date: Date) {
        defer { self.lastTickDate = date }
        guard let last = self.lastTickDate else { return }
        let elapsed = date.timeIntervalSince(last)
        // Ignore outliers: first tick after resume, extremely slow machine, etc.
        guard elapsed > 0, elapsed < 1.0 else {
            self.slowFrameAccum = 0
            return
        }
        let fps = 1.0 / elapsed
        if fps < 30 {
            self.slowFrameAccum += elapsed
            if self.slowFrameAccum >= 3.0, !self.hasAutoSimplified {
                self.hasAutoSimplified = true
                self.vm.autoSimplify()
            }
        } else {
            self.slowFrameAccum = 0
        }
    }

    // MARK: - Renderer management

    private func rebuildRenderer() {
        let key = "\(vm.mode.rawValue)-\(self.vm.palette.rawValue)-\(self.reduceMotion)-\(self.reduceTransparency)"
        guard key != self.rendererKey else { return }
        self.rendererKey = key

        switch self.vm.mode {
        case .spectrumBars:
            self.renderer = SpectrumBars(
                palette: self.vm.palette,
                reduceMotion: self.reduceMotion,
                reduceTransparency: self.reduceTransparency
            )

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
        L10n.string("Visualizer: \(self.vm.mode.displayName)")
    }

    // MARK: - Performance toast

    private func performanceToastBanner(toast: ToastMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .foregroundStyle(.secondary)
            Text(toast.text)
                .font(.subheadline)
            if self.vm.modeBeforeAutoSimplify != nil {
                Button(L10n.string("Revert")) { self.vm.revertAutoSimplify() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(L10n.string("Revert visualizer mode"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(
                self.reduceTransparency
                    ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                    : AnyShapeStyle(Material.ultraThin)
            )
        )
        .foregroundStyle(.white)
    }
}

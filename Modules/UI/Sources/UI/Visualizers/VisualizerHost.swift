import AudioEngine
import SwiftUI

// MARK: - VisualizerHost

/// Container view that drives the active visualizer mode at display rate.
///
/// Most modes render through `TimelineView` + Canvas. When a mode has a Metal
/// renderer and a Metal device is available, the host swaps in an
/// `MTKView`-backed path instead; the Canvas renderer is always built too and
/// serves as the fallback (no device, or the `visualizer.forceCanvas` debug
/// default). Both paths share the toast overlay, accessibility label, and FPS
/// watchdog.
public struct VisualizerHost: View {
    // MARK: - Dependencies

    @ObservedObject public var vm: VisualizerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // MARK: - Local state

    /// Active Canvas renderer instance. Rebuilt only when mode, palette, or a11y
    /// changes. Always present (Metal fallback / reference).
    @State private var renderer: (any Visualizer)?
    /// Active Metal renderer, or nil when the current mode has no Metal renderer
    /// (every mode in the foundations phase) or Metal is unavailable.
    @State private var metalRenderer: (any MetalVisualizer)?
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
            self.activeContent
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

    // MARK: - Content routing

    /// The Metal path when a Metal renderer is active, otherwise the Canvas path.
    /// The `.id(rendererKey)` tears the `MTKView` down and rebuilds it on a mode,
    /// palette, or accessibility change rather than mutating a live renderer.
    ///
    /// The Metal path runs its own frame-rate watchdog inside the view's
    /// coordinator (see ``FrameRateMonitor``); unlike the Canvas path's
    /// `recordFrameTick`, it deliberately does not touch this view's `@State`,
    /// because mutating it every frame would re-evaluate `body` (and re-query the
    /// battery via `effectiveFPS`) at the display rate.
    @ViewBuilder
    private var activeContent: some View {
        if let metalRenderer, let device = MetalSupport.device {
            MetalVisualizerView(
                renderer: metalRenderer,
                vm: self.vm,
                device: device,
                pixelFormat: .bgra8Unorm,
                preferredFPS: self.vm.effectiveFPS,
                reduceMotion: self.reduceMotion
            )
            .id(self.rendererKey)
        } else {
            self.timelineCanvas
        }
    }

    // MARK: - Canvas (non-Metal modes)

    @ViewBuilder
    private var timelineCanvas: some View {
        let interval = 1.0 / Double(self.vm.effectiveFPS)
        TimelineView(.animation(minimumInterval: interval, paused: false)) { tl in
            let time = tl.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                guard let r = renderer else { return }
                var ctx = context
                r.render(into: &ctx, size: size, samples: self.latestSamples, analysis: self.vm.analysis, time: time)
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

        self.buildMetalRenderer()
        self.buildCanvasRenderer()
    }

    /// Attempts to build a Metal renderer for the current mode. Leaves
    /// `metalRenderer` nil (Canvas fallback) when no device exists, the mode has
    /// no Metal renderer, the user forced Canvas, or the renderer's init threw.
    private func buildMetalRenderer() {
        self.metalRenderer = nil
        guard
            let device = MetalSupport.device,
            !UserDefaults.standard.bool(forKey: "visualizer.forceCanvas"),
            MetalVisualizerFactory.supports(self.vm.mode) else { return }
        let config = MetalRendererConfig(
            palette: self.vm.palette,
            reduceMotion: self.reduceMotion,
            reduceTransparency: self.reduceTransparency
        )
        self.metalRenderer = MetalVisualizerFactory.make(
            mode: self.vm.mode,
            device: device,
            pixelFormat: .bgra8Unorm,
            config: config
        )
    }

    /// Builds the Canvas renderer for the current mode. Always built: it is the
    /// fallback when Metal is unavailable and the visual-parity reference, and it
    /// costs nothing until actually rendered.
    private func buildCanvasRenderer() {
        switch self.vm.mode {
        case .spectrumBars:
            self.renderer = SpectrumBars(
                palette: self.vm.palette,
                reduceMotion: self.reduceMotion,
                reduceTransparency: self.reduceTransparency
            )

        case .oscilloscope:
            self.renderer = Oscilloscope(palette: self.vm.palette, reduceMotion: self.reduceMotion)

        case .halo:
            self.renderer = Halo(
                palette: self.vm.palette,
                reduceMotion: self.reduceMotion,
                reduceTransparency: self.reduceTransparency
            )

        case .cascade:
            self.renderer = Cascade(
                palette: self.vm.palette,
                reduceMotion: self.reduceMotion,
                reduceTransparency: self.reduceTransparency
            )

        case .starfield:
            self.renderer = Starfield(
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

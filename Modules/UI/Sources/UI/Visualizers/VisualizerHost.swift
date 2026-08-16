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

    /// Owns both the auto-simplify watchdog and (ADR-084, E2E only) the
    /// rolling FPS fed to `VisualizerViewModel.recordLiveFrame`. Canvas mode
    /// already re-evaluates `body` every tick via `TimelineView`, unlike the
    /// stricter Metal path (see `activeContent`'s doc comment), so mutating
    /// this `@State` per frame here is the existing, accepted cost.
    @State private var frameMonitor = FrameRateMonitor()

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
        // No .accessibilityIdentifier here: A11y.Visualizer.host lives on
        // VisualizerControlOverlay's zero-size readout element instead
        // (see LivenessAccessibilityValue's doc comment) — two elements
        // sharing one identifier would make `.firstMatch` non-deterministic
        // about which one (this label-only one, or that value-bearing one)
        // a query resolves to. The label stays here for VoiceOver users
        // navigating to the render area itself.
        .accessibilityLabel(self.accessibilityLabel)
        .onAppear { self.rebuildRenderer() }
        .onChange(of: self.vm.mode) { _, _ in
            self.rebuildRenderer()
            // Reset FPS monitor so a manual mode change (or revert) gets a
            // fresh 3-second window before another auto-simplify can fire.
            self.frameMonitor = FrameRateMonitor()
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
        if self.frameMonitor.record(time: date.timeIntervalSinceReferenceDate) {
            self.vm.autoSimplify()
        }
        // A no-op unless E2E liveness is on; see VisualizerViewModel.
        self.vm.recordLiveFrame(fps: self.frameMonitor.currentFPS)
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
            MetalVisualizerFactory.supports(self.vm.mode),
            !(self.vm.mode.requiresMetal && self.reduceMotion) else { return }
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

        case .nebula:
            // Nebula is Metal-only; the Canvas fallback used when Metal is
            // unavailable, forced off, or Reduce Motion is on is the calm Spectrum Bars.
            self.renderer = SpectrumBars(
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

// MARK: - LivenessAccessibilityValue

/// Applies `VisualizerViewModel.currentFPS` as an accessibility value only
/// under `e2eLiveness` — never for a real user, whose accessibility tree
/// must not carry this internal metric (ADR-084). Always applies the
/// modifier (an empty value reads as no value to VoiceOver) rather than
/// branching to a differently-shaped view per condition, which resets
/// SwiftUI's identity for the wrapped content and can silently drop
/// modifiers applied to it further up the chain. Not `private`: shared by
/// `VisualizerControlOverlay`, common to all three visualizer surfaces.
struct LivenessAccessibilityValue: ViewModifier {
    @ObservedObject var vm: VisualizerViewModel

    func body(content: Content) -> some View {
        content.accessibilityValue(
            self.vm.e2eLiveness ? L10n.string("\(Int(self.vm.currentFPS.rounded())) fps") : ""
        )
    }
}

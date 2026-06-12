import AudioEngine
import MetalKit
import Observability
import SwiftUI

// MARK: - MetalVisualizerView

/// Hosts a ``MetalVisualizer`` in an `MTKView`, driving it at the display's
/// refresh rate.
///
/// SwiftUI Canvas cannot encode Metal commands, so this is the one place the
/// visualizer stack drops to AppKit. The view owns the render pass, command
/// buffer, present, and commit; the renderer only updates CPU state and encodes
/// draw calls. Frame timing feeds the same FPS watchdog the Canvas path uses, so
/// a sustained slow Metal mode auto-simplifies identically.
struct MetalVisualizerView: NSViewRepresentable {
    let renderer: any MetalVisualizer
    let vm: VisualizerViewModel
    let device: MTLDevice
    let pixelFormat: MTLPixelFormat
    let preferredFPS: Int
    let reduceMotion: Bool
    /// Called once per presented frame, wired to the host's `recordFrameTick`.
    let onFrame: (Date) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            renderer: self.renderer,
            vm: self.vm,
            device: self.device,
            reduceMotion: self.reduceMotion,
            onFrame: self.onFrame
        )
    }

    func makeNSView(context: Context) -> VisualizerMTKView {
        let view = VisualizerMTKView(frame: .zero, device: self.device)
        view.colorPixelFormat = self.pixelFormat
        view.clearColor = MTLClearColorMake(0, 0, 0, 1) // opaque black; descriptor clears to it
        view.framebufferOnly = true
        view.autoResizeDrawable = false // we size the drawable from renderScale
        view.enableSetNeedsDisplay = false // continuous (paused = false) driving
        view.isPaused = false
        view.preferredFramesPerSecond = self.preferredFPS
        // Plain .bgra8Unorm + an sRGB layer colorspace keeps colours gamma-encoded
        // for parity with the Canvas renderers (see ColorPacking). Do not switch to
        // a *_srgb pixel format; that re-encodes and washes the output out.
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.targetScale = self.renderer.renderScale
        view.alphaValue = 0 // warm-up: fade in after the first drawable presents
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: VisualizerMTKView, context: Context) {
        // Re-apply on every update so the Settings FPS cap and battery cap keep
        // working, and refresh the tick callback so it captures current state.
        view.preferredFramesPerSecond = self.preferredFPS
        context.coordinator.onFrame = self.onFrame
    }

    static func dismantleNSView(_ view: VisualizerMTKView, coordinator: Coordinator) {
        // Pause before nilling the delegate, or the GPU keeps drawing for a
        // closed pane (the phase 12 fullscreen open/close bug).
        view.isPaused = true
        view.delegate = nil
    }
}

// MARK: - VisualizerMTKView

/// `MTKView` subclass that sizes its drawable from the renderer's render scale
/// (1.0 for every mode except an adaptive one). `targetScale` is pushed in by
/// the coordinator; `layout()` keeps the drawable correct across live resizes.
final class VisualizerMTKView: MTKView {
    var targetScale: CGFloat = 1

    override func layout() {
        super.layout()
        self.applyDrawableSize()
    }

    /// Sets `drawableSize` to the backing-pixel bounds scaled by `targetScale`.
    /// Cheap and idempotent: a no-op when the size already matches.
    func applyDrawableSize() {
        let backing = self.convertToBacking(self.bounds.size)
        let target = CGSize(
            width: max(1, (backing.width * self.targetScale).rounded()),
            height: max(1, (backing.height * self.targetScale).rounded())
        )
        if self.drawableSize != target {
            self.drawableSize = target
        }
    }
}

// MARK: - Coordinator

extension MetalVisualizerView {
    /// `MTKViewDelegate` that runs the per-frame loop. `MTKView` calls the
    /// delegate on the main thread, so the nonisolated requirements hop straight
    /// into the main actor where the renderer and view model live.
    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private let renderer: any MetalVisualizer
        private let vm: VisualizerViewModel
        private let reduceMotion: Bool
        private let commandQueue: MTLCommandQueue?
        private let log = AppLogger.make(.ui)
        private var hasPresentedFirstFrame = false
        var onFrame: (Date) -> Void

        private static let silentSamples = AudioSamples(
            timeStamp: .init(), sampleRate: 44100, mono: [], left: [], right: [], rms: 0, peak: 0
        )

        init(
            renderer: any MetalVisualizer,
            vm: VisualizerViewModel,
            device: MTLDevice,
            reduceMotion: Bool,
            onFrame: @escaping (Date) -> Void
        ) {
            self.renderer = renderer
            self.vm = vm
            self.reduceMotion = reduceMotion
            self.commandQueue = device.makeCommandQueue()
            self.onFrame = onFrame
            super.init()
            if self.commandQueue == nil {
                self.log.error("visualizer.metal.commandQueue.failed")
            }
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                self.drawFrame(in: view)
            }
        }

        private func drawFrame(in view: MTKView) {
            guard let view = view as? VisualizerMTKView, let queue = self.commandQueue else { return }
            // Re-check render scale each frame so an adaptive mode takes effect
            // without waiting for a resize.
            view.targetScale = self.renderer.renderScale
            view.applyDrawableSize()

            // Acquire the drawable and encoder BEFORE update(): a renderer may
            // take a per-frame resource (a FrameRing slot) in update() and release
            // it in didEncode(), so skipping the draw after update() would leak the
            // slot and deadlock the ring. Guarding first keeps update -> encode ->
            // didEncode atomic. A nil descriptor (window miniaturised, display
            // asleep) skips the whole frame, silently (logging per frame would
            // flood the ring buffer).
            guard
                let descriptor = view.currentRenderPassDescriptor,
                let drawable = view.currentDrawable,
                let commandBuffer = queue.makeCommandBuffer(),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            // Read the freshest analysis at draw time: this is what keeps the
            // visuals locked to what is currently being heard.
            let samples = self.vm.latestSamples ?? Self.silentSamples
            self.renderer.update(
                analysis: self.vm.analysis,
                samples: samples,
                time: CACurrentMediaTime(),
                drawableSize: view.drawableSize
            )

            self.renderer.encode(into: encoder)
            encoder.endEncoding()
            self.renderer.didEncode(commandBuffer: commandBuffer)
            commandBuffer.present(drawable)
            commandBuffer.commit()

            if !self.hasPresentedFirstFrame {
                self.hasPresentedFirstFrame = true
                self.fadeIn(view)
            }
            self.onFrame(Date())
        }

        /// Fades the view up from transparent once the first frame is on screen,
        /// so launch reads as a soft reveal over black, never a flash. Immediate
        /// under reduce motion.
        private func fadeIn(_ view: NSView) {
            guard !self.reduceMotion else {
                view.alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                view.animator().alphaValue = 1
            }
        }
    }
}

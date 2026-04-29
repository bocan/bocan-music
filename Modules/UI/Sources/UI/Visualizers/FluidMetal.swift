import AppKit // NSViewRepresentable — only AppKit use in this module is allowed in UI
import AudioEngine
import Metal
import MetalKit
import SwiftUI

// MARK: - FluidMetal

/// A Metal-based particle visualizer.
///
/// 3 000 particles are driven by a compute shader. Bass energy accelerates them;
/// spectral centroid shifts the hue. Falls back to ``SpectrumBars`` when Metal
/// is unavailable, `reduceTransparency` is on, or `reduceMotion` is requested.
///
/// **Metal render paths are exempt from the 80% line-coverage goal** because
/// headless test environments lack a GPU. All logic paths reachable without a
/// device are tested in `VisualizerViewModelTests`.
@MainActor
public final class FluidMetal: Visualizer {
    // MARK: - Constants

    private static let particleCount = 3000

    // MARK: - Dependencies

    let device: MTLDevice?
    var commandQueue: MTLCommandQueue?
    private var computePipeline: MTLComputePipelineState?
    private var renderPipeline: MTLRenderPipelineState?
    private var particleBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    var isReady = false

    private let fallback: SpectrumBars
    private let palette: VisualizerPalette
    private let reduceMotion: Bool
    private let reduceTransparency: Bool

    // MARK: - Analysis state (written from MainActor before render)

    var bassEnergy: Float = 0
    var spectralCentroid: Float = 0

    // MARK: - Init

    public init(
        palette: VisualizerPalette = .accent,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false
    ) {
        self.palette = palette
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.fallback = SpectrumBars(palette: palette, reduceMotion: reduceMotion)
        self.device = MTLCreateSystemDefaultDevice()
        self.setupMetal()
    }

    // MARK: - Visualizer

    public func render(
        into context: inout GraphicsContext,
        size: CGSize,
        samples: AudioSamples,
        analysis: Analysis
    ) {
        // reduceMotion or reduceTransparency → fall back to the simpler bars view.
        guard !self.reduceMotion, !self.reduceTransparency, self.isReady else {
            self.fallback.render(into: &context, size: size, samples: samples, analysis: analysis)
            return
        }

        // Update analysis state used by the compute pass.
        let bands = analysis.bands
        let bandCount = bands.count
        if bandCount >= 4 {
            self.bassEnergy = (bands[0] + bands[1] + bands[2] + bands[3]) / 4
        }
        // Spectral centroid: weighted average bin index / band count.
        var weightedSum: Float = 0
        var totalWeight: Float = 0
        for (i, b) in bands.enumerated() {
            weightedSum += Float(i) * b
            totalWeight += b
        }
        self.spectralCentroid = totalWeight > 0 ? weightedSum / (totalWeight * Float(bandCount)) : 0

        // The actual GPU work (compute + render passes) is performed by `FluidMetalView`
        // (MTKView subclass) which drives its own CVDisplayLink-synced draw loop.
        // `FluidMetal.render(into:)` is called by VisualizerHost's TimelineView and
        // only updates analysis state here; GPU submission happens in the MTKView delegate.
        //
        // For the Canvas snapshot (used in tests and reduceMotion mode), we draw a
        // simple energy blob so the code path is exercised.
        self.renderCanvasFallback(into: &context, size: size, analysis: analysis)
    }

    // MARK: - Private: canvas fallback (used in snapshots + non-Metal environments)

    private func renderCanvasFallback(
        into context: inout GraphicsContext,
        size: CGSize,
        analysis: Analysis
    ) {
        let cx = size.width / 2
        let cy = size.height / 2
        let radius = min(size.width, size.height) * 0.35 * (0.5 + CGFloat(analysis.rms) * 0.5)
        let hue = Double(spectralCentroid)
        let color = Color(hue: hue, saturation: 0.8, brightness: 0.9)
        let circle = Path(ellipseIn: CGRect(
            x: cx - radius,
            y: cy - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.fill(circle, with: .color(color.opacity(0.6)))
    }

    // MARK: - Metal setup

    private func setupMetal() {
        guard let device else { return }
        guard let queue = device.makeCommandQueue() else { return }
        self.commandQueue = queue

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let computeFn = try requiredFunction("updateParticles", from: library)
            let vertexFn = try requiredFunction("particleVertex", from: library)
            let fragmentFn = try requiredFunction("particleFragment", from: library)

            self.computePipeline = try device.makeComputePipelineState(function: computeFn)

            let rpd = MTLRenderPipelineDescriptor()
            rpd.vertexFunction = vertexFn
            rpd.fragmentFunction = fragmentFn
            rpd.colorAttachments[0].pixelFormat = .bgra8Unorm
            rpd.colorAttachments[0].isBlendingEnabled = true
            rpd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            rpd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            self.renderPipeline = try device.makeRenderPipelineState(descriptor: rpd)

            self.particleBuffer = self.makeParticleBuffer(device: device)
            self.uniformBuffer = device.makeBuffer(
                length: MemoryLayout<FluidUniforms>.stride,
                options: .storageModeShared
            )
            self.isReady = true
        } catch {
            // Metal setup failure is non-fatal; fall back to canvas rendering.
            self.isReady = false
        }
    }

    private func requiredFunction(_ name: String, from library: MTLLibrary) throws -> MTLFunction {
        guard let fn = library.makeFunction(name: name) else {
            throw FluidMetalError.missingFunction(name)
        }
        return fn
    }

    private func makeParticleBuffer(device: MTLDevice) -> MTLBuffer? {
        let count = Self.particleCount
        var particles = [FluidParticle](repeating: FluidParticle(), count: count)
        for i in 0 ..< count {
            particles[i].position = SIMD2<Float>(
                Float.random(in: -1 ... 1),
                Float.random(in: -1 ... 1)
            )
            particles[i].velocity = SIMD2<Float>(
                Float.random(in: -0.01 ... 0.01),
                Float.random(in: -0.01 ... 0.01)
            )
            particles[i].life = Float.random(in: 0 ... 1)
        }
        return device.makeBuffer(
            bytes: &particles,
            length: MemoryLayout<FluidParticle>.stride * count,
            options: .storageModeShared
        )
    }

    // MARK: - MTKView bridge (used by FluidMetalView)

    func updateUniforms(bassEnergy: Float, centroid: Float, time: Float) {
        guard let ptr = uniformBuffer?.contents().bindMemory(
            to: FluidUniforms.self, capacity: 1
        ) else { return }
        ptr.pointee = FluidUniforms(
            bassEnergy: bassEnergy,
            spectralCentroid: centroid,
            time: time,
            particleCount: UInt32(Self.particleCount)
        )
    }

    func submitComputeAndRender(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        guard let computePipeline,
              let renderPipeline,
              let particleBuffer,
              let uniformBuffer else { return }

        // Compute pass: update particle positions.
        if let ce = commandBuffer.makeComputeCommandEncoder() {
            ce.setComputePipelineState(computePipeline)
            ce.setBuffer(particleBuffer, offset: 0, index: 0)
            ce.setBuffer(uniformBuffer, offset: 0, index: 1)
            let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
            let groups = MTLSize(width: (Self.particleCount + 63) / 64, height: 1, depth: 1)
            ce.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
            ce.endEncoding()
        }

        // Render pass: draw particles as points.
        if let re = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            re.setRenderPipelineState(renderPipeline)
            re.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            re.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            re.drawPrimitives(
                type: .point,
                vertexStart: 0,
                vertexCount: Self.particleCount
            )
            re.endEncoding()
        }
    }
}

// MARK: - FluidMetalError

private enum FluidMetalError: Error {
    case missingFunction(String)
}

// MARK: - GPU types

private struct FluidParticle {
    var position: SIMD2<Float> = .zero
    var velocity: SIMD2<Float> = .zero
    var life: Float = 0
    var pad: Float = 0
}

private struct FluidUniforms {
    var bassEnergy: Float
    var spectralCentroid: Float
    var time: Float
    var particleCount: UInt32
}

// MARK: - FluidMetalView (MTKView + NSViewRepresentable bridge)

/// NSViewRepresentable drop-down to AppKit: MTKView requires AppKit; no SwiftUI equivalent exists.
struct FluidMetalView: NSViewRepresentable {
    let renderer: FluidMetal

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = self.renderer.device
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.colorPixelFormat = .bgra8Unorm
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: self.renderer)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {
        // @unchecked Sendable: all access is from the main thread (MTKView delegate callbacks).
        private let renderer: FluidMetal
        private var startTime = Date()

        init(renderer: FluidMetal) {
            self.renderer = renderer
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            // MTKView delivers draw callbacks on the main thread.
            Task { @MainActor in
                self.drawFrame(in: view)
            }
        }

        private func drawFrame(in view: MTKView) {
            guard self.renderer.isReady,
                  let commandQueue = renderer.commandQueue,
                  let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            let elapsed = Float(Date().timeIntervalSince(self.startTime))
            self.renderer.updateUniforms(
                bassEnergy: self.renderer.bassEnergy,
                centroid: self.renderer.spectralCentroid,
                time: elapsed
            )
            self.renderer.submitComputeAndRender(
                commandBuffer: commandBuffer,
                renderPassDescriptor: rpd
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// MARK: - Metal shader source (compiled at runtime)

private extension FluidMetal {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Particle {
        float2 position;
        float2 velocity;
        float  life;
        float  pad;
    };

    struct Uniforms {
        float    bassEnergy;
        float    spectralCentroid;
        float    time;
        uint     particleCount;
    };

    // Compute shader: update particle positions each frame.
    kernel void updateParticles(device Particle* particles [[buffer(0)]],
                                constant Uniforms& u        [[buffer(1)]],
                                uint id [[thread_position_in_grid]])
    {
        if (id >= u.particleCount) return;
        Particle p = particles[id];

        // Bass-driven acceleration toward origin (creates pulsing effect).
        float2 toOrigin = -p.position;
        float dist = max(length(toOrigin), 0.001);
        float bassPush = u.bassEnergy * 0.02;
        p.velocity += normalize(toOrigin) * bassPush * (1.0 - dist * 0.5);

        // Gentle swirl using spectral centroid as angular velocity modifier.
        float angle = u.time * (0.3 + u.spectralCentroid * 0.5);
        float2x2 rot = float2x2(cos(angle), -sin(angle), sin(angle), cos(angle));
        p.velocity = rot * p.velocity * 0.995;  // drag

        p.position += p.velocity;

        // Wrap around edges.
        if (p.position.x > 1.1) { p.position.x = -1.1; }
        if (p.position.x < -1.1) { p.position.x = 1.1; }
        if (p.position.y > 1.1) { p.position.y = -1.1; }
        if (p.position.y < -1.1) { p.position.y = 1.1; }

        p.life = fmod(p.life + 0.005, 1.0);
        particles[id] = p;
    }

    struct VertexOut {
        float4 position [[position]];
        float  pointSize [[point_size]];
        float4 color;
    };

    // Vertex shader: map particle NDC position to clip space, colour by centroid.
    vertex VertexOut particleVertex(uint vid [[vertex_id]],
                                    device const Particle* particles [[buffer(0)]],
                                    constant Uniforms& u [[buffer(1)]])
    {
        Particle p = particles[vid];
        float hue = u.spectralCentroid + p.life * 0.3;
        // HSV to RGB (simplified for Metal)
        float s = 0.8, v = 0.9;
        float3 rgb = v * (1.0 - s * abs(fract(hue * 6.0 + float3(0,4,2)/6.0) * 2.0 - 1.0));

        float alpha = 0.4 + p.life * 0.4;
        VertexOut out;
        out.position  = float4(p.position, 0, 1);
        out.pointSize = 3.0 + u.bassEnergy * 4.0;
        out.color     = float4(rgb, alpha);
        return out;
    }

    // Fragment shader: circular soft point sprite.
    fragment float4 particleFragment(VertexOut in [[stage_in]],
                                     float2 pointCoord [[point_coord]])
    {
        float dist = length(pointCoord - float2(0.5));
        if (dist > 0.5) discard_fragment();
        float alpha = in.color.a * (1.0 - dist * 2.0);
        return float4(in.color.rgb, alpha);
    }
    """
}

import Metal

// MARK: - Alpha-blended render pipeline

extension MTLDevice {
    /// Builds a render pipeline for `vertexFunction`/`fragmentFunction` targeting
    /// `pixelFormat` with standard (straight) alpha blending -- the exact
    /// configuration every blended visualizer renderer (spectrum bars,
    /// oscilloscope, halo, starfield) sets up. A build failure is mapped to
    /// ``MetalRendererError/pipelineCreationFailed(reason:)``.
    func makeAlphaBlendedPipeline(
        vertexFunction: MTLFunction,
        fragmentFunction: MTLFunction,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let attachment = descriptor.colorAttachments[0]
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .sourceAlpha
        attachment?.sourceAlphaBlendFactor = .sourceAlpha
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            return try self.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(reason: String(reflecting: error))
        }
    }
}

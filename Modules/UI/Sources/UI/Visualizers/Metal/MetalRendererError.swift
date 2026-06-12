import Foundation

// MARK: - MetalRendererError

/// Setup failures shared by the Metal renderers. A thrown case turns into a
/// logged `nil` from the factory, so the host falls back to the Canvas renderer
/// for that mode rather than crashing.
enum MetalRendererError: Error {
    /// `device.makeRenderPipelineState` failed.
    case pipelineCreationFailed(reason: String)
    /// A required GPU resource (buffer, texture, ring) could not be allocated.
    case resourceAllocationFailed(reason: String)
    /// A shader function was missing from a successfully compiled library.
    case missingFunction(name: String)
}

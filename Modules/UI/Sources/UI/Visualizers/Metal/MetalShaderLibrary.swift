import Foundation
import Metal
import Observability

// MARK: - MetalShaderError

/// Errors raised while loading or compiling a Metal shader source.
enum MetalShaderError: Error {
    /// No `Resources/Shaders/<name>.metal` resource was found in the module bundle.
    case resourceNotFound(name: String)
    /// `device.makeLibrary(source:options:)` failed; carries the compiler diagnostics.
    case compilationFailed(name: String, diagnostics: String)
}

// MARK: - MetalShaderLibrary

/// Loads and compiles Metal shaders at runtime from bundled `.metal` source,
/// caching the resulting `MTLLibrary` per device-and-name.
///
/// **Why runtime compilation rather than a prebuilt `default.metallib`?**
/// SwiftPM can in principle compile `.metal` sources into a metallib, but the
/// behaviour differs between `xcodebuild`, `swift build`, and `swift test`, and
/// this module's tests run under `swift test` (`make test-ui`). One code path
/// that works identically everywhere beats a faster path that works in three of
/// four contexts. Shaders are small; compilation costs a few milliseconds, once
/// per renderer lifetime, and the result is cached.
@MainActor
enum MetalShaderLibrary {
    private static let log = AppLogger.make(.ui)

    /// Compiled libraries keyed by `"<deviceRegistryID>:<name>"`, so two devices
    /// (e.g. a future eGPU) never share a library and repeated lookups are free.
    private static var cache: [String: MTLLibrary] = [:]

    /// Loads `Resources/Shaders/<name>.metal` from `Bundle.module`, compiles it,
    /// and caches the library. Subsequent calls with the same name and device
    /// return the cached instance.
    ///
    /// - Throws: ``MetalShaderError/resourceNotFound(name:)`` if the resource is
    ///   missing, ``MetalShaderError/compilationFailed(name:diagnostics:)`` on a
    ///   compiler error.
    static func library(named name: String, device: MTLDevice) throws -> MTLLibrary {
        if let cached = self.cache[cacheKey(name: name, device: device)] {
            return cached
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "metal", subdirectory: "Shaders") else {
            self.log.error("visualizer.metal.shader.missing", ["name": name])
            throw MetalShaderError.resourceNotFound(name: name)
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        return try self.compile(name: name, source: source, device: device)
    }

    /// Compiles `source` into a library, caching it under `name`. Exposed for
    /// tests so runtime compilation can be proven without a bundled `.metal`
    /// file, and shared by ``library(named:device:)``.
    static func compile(name: String, source: String, device: MTLDevice) throws -> MTLLibrary {
        let key = Self.cacheKey(name: name, device: device)
        if let cached = self.cache[key] {
            return cached
        }
        let start = DispatchTime.now()
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            self.cache[key] = library
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            self.log.debug("visualizer.metal.shader.compiled", ["name": name, "ms": ms])
            return library
        } catch {
            self.log.error("visualizer.metal.shader.failed", [
                "name": name,
                "error": String(reflecting: error),
            ])
            throw MetalShaderError.compilationFailed(name: name, diagnostics: String(describing: error))
        }
    }

    private static func cacheKey(name: String, device: MTLDevice) -> String {
        "\(device.registryID):\(name)"
    }
}

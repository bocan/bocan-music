import Metal
import Testing
@testable import UI

// MARK: - MetalShaderLibraryTests

/// Proves runtime shader compilation works under `swift test` (the central
/// build risk the foundations phase exists to de-risk) and that the per-device
/// cache returns a stable instance. Skipped on machines without a Metal device.
@Suite("MetalShaderLibrary")
@MainActor
struct MetalShaderLibraryTests {
    private static let validSource = """
    #include <metal_stdlib>
    using namespace metal;

    vertex float4 test_vertex(uint vid [[vertex_id]]) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    fragment float4 test_fragment() {
        return float4(1.0, 1.0, 1.0, 1.0);
    }
    """

    @Test("A valid source compiles and exposes its functions")
    func compilesValidSource() throws {
        guard let device = MetalSupport.device else { return }
        let library = try MetalShaderLibrary.compile(name: "valid-\(#function)", source: Self.validSource, device: device)
        #expect(library.makeFunction(name: "test_vertex") != nil)
        #expect(library.makeFunction(name: "test_fragment") != nil)
    }

    @Test("An invalid source throws compilationFailed with diagnostics")
    func invalidSourceThrows() {
        guard let device = MetalSupport.device else { return }
        let broken = "this is not valid metal shading language { ;;; }"
        #expect(throws: MetalShaderError.self) {
            try MetalShaderLibrary.compile(name: "broken-\(#function)", source: broken, device: device)
        }
        do {
            _ = try MetalShaderLibrary.compile(name: "broken2-\(#function)", source: broken, device: device)
            Issue.record("expected compilation to throw")
        } catch let MetalShaderError.compilationFailed(name, diagnostics) {
            #expect(name == "broken2-\(#function)")
            #expect(!diagnostics.isEmpty)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("The cache returns the identical library instance on a repeat call")
    func cacheReturnsSameInstance() throws {
        guard let device = MetalSupport.device else { return }
        let name = "cache-\(#function)"
        let first = try MetalShaderLibrary.compile(name: name, source: Self.validSource, device: device)
        let second = try MetalShaderLibrary.compile(name: name, source: Self.validSource, device: device)
        #expect(first === second)
    }

    @Test("A missing bundled resource throws resourceNotFound")
    func missingResourceThrows() {
        guard let device = MetalSupport.device else { return }
        #expect(throws: MetalShaderError.self) {
            try MetalShaderLibrary.library(named: "no-such-shader", device: device)
        }
    }
}

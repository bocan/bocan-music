import AudioEngine
import Foundation
import Testing
@testable import UI

// MARK: - VisualizerHostOverrideTests

/// ADR-089: a surface may pin its own mode and palette without touching the
/// saved preference. The pure selection logic is tested directly; the host's
/// use of it is checked as a source convention, because the live render path
/// cannot be exercised host-less (see `MetalHostRoutingTests`).
@Suite("Visualizer per-surface override")
@MainActor
struct VisualizerHostOverrideTests {
    // MARK: - Selection

    @Test("followsPreferences resolves to the saved mode and palette")
    func followsPreferences() {
        let selection = VisualizerSurfaceSelection.followsPreferences
        #expect(!selection.overridesPreferences)
        #expect(selection.effectiveMode(preferred: .nebula) == .nebula)
        #expect(selection.effectivePalette(preferred: .accent) == .accent)
    }

    @Test("a pinned mode and palette win over the saved preference")
    func pinnedValuesWin() {
        let selection = VisualizerSurfaceSelection(mode: .oscilloscope, palette: .drift)
        #expect(selection.overridesPreferences)
        #expect(selection.effectiveMode(preferred: .nebula) == .oscilloscope)
        #expect(selection.effectivePalette(preferred: .accent) == .drift)
    }

    @Test("pinning only one value leaves the other following the preference")
    func partialPin() {
        let modeOnly = VisualizerSurfaceSelection(mode: .halo, palette: nil)
        #expect(modeOnly.overridesPreferences)
        #expect(modeOnly.effectiveMode(preferred: .cascade) == .halo)
        #expect(modeOnly.effectivePalette(preferred: .ember) == .ember)

        let paletteOnly = VisualizerSurfaceSelection(mode: nil, palette: .mono)
        #expect(paletteOnly.overridesPreferences)
        #expect(paletteOnly.effectiveMode(preferred: .cascade) == .cascade)
        #expect(paletteOnly.effectivePalette(preferred: .ember) == .mono)
    }

    @Test("renderer key changes with every input and is stable otherwise")
    func rendererKey() {
        let base = VisualizerSurfaceSelection.rendererKey(
            mode: .oscilloscope, palette: .drift, reduceMotion: false, reduceTransparency: false
        )
        let same = VisualizerSurfaceSelection.rendererKey(
            mode: .oscilloscope, palette: .drift, reduceMotion: false, reduceTransparency: false
        )
        #expect(base == same)
        #expect(base != VisualizerSurfaceSelection.rendererKey(
            mode: .halo, palette: .drift, reduceMotion: false, reduceTransparency: false
        ))
        #expect(base != VisualizerSurfaceSelection.rendererKey(
            mode: .oscilloscope, palette: .mono, reduceMotion: false, reduceTransparency: false
        ))
        #expect(base != VisualizerSurfaceSelection.rendererKey(
            mode: .oscilloscope, palette: .drift, reduceMotion: true, reduceTransparency: false
        ))
        #expect(base != VisualizerSurfaceSelection.rendererKey(
            mode: .oscilloscope, palette: .drift, reduceMotion: false, reduceTransparency: true
        ))
    }

    // MARK: - Host

    @Test("a pinned host reads the pinned values and leaves the view model untouched")
    func hostEffectiveValues() {
        let vm = VisualizerViewModel(engine: AudioEngine())
        let savedMode = vm.mode
        let savedPalette = vm.palette
        defer {
            vm.mode = savedMode
            vm.palette = savedPalette
        }
        vm.mode = .nebula
        vm.palette = .accent

        let pinned = VisualizerHost(vm: vm, mode: .oscilloscope, palette: .drift)
        #expect(pinned.effectiveMode == .oscilloscope)
        #expect(pinned.effectivePalette == .drift)
        #expect(vm.mode == .nebula)
        #expect(vm.palette == .accent)

        let following = VisualizerHost(vm: vm)
        #expect(following.effectiveMode == .nebula)
        #expect(following.effectivePalette == .accent)
    }

    // MARK: - Source conventions

    private func hostSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Visualizers/VisualizerHost.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the host builds renderers from the effective values, never the raw preference")
    func hostUsesEffectiveValues() throws {
        let source = try self.hostSource()
        #expect(!source.contains("vm.mode.rawValue"))
        #expect(!source.contains("MetalVisualizerFactory.supports(self.vm.mode)"))
        #expect(!source.contains("switch self.vm.mode"))
        #expect(!source.contains("palette: self.vm.palette"))
        #expect(source.contains("VisualizerSurfaceSelection.rendererKey("))
    }

    @Test("the host never writes the saved mode or palette")
    func hostNeverWritesPreference() throws {
        let source = try self.hostSource()
        #expect(!source.contains("vm.mode ="))
        #expect(!source.contains("vm.palette ="))
    }

    @Test("auto-simplify is gated on both render paths")
    func autoSimplifyGated() throws {
        let hostSource = try self.hostSource()
        #expect(hostSource.contains("self.autoSimplifies {"))
        #expect(hostSource.contains("autoSimplifies: self.autoSimplifies"))

        let metalURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/Visualizers/Metal/MetalVisualizerView.swift")
        let metalSource = try String(contentsOf: metalURL, encoding: .utf8)
        #expect(metalSource.contains("self.autoSimplifies {"))
    }
}

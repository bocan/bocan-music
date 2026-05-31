import AppKit
import AudioEngine
import SnapshotTesting
import SwiftUI
import Testing
@testable import Persistence
@testable import UI

// MARK: - High-Contrast Snapshots

extension UISnapshotTests {
    @Suite("High Contrast Snapshots")
    @MainActor
    struct HighContrastSnapshotTests {
        private static let stripSize = CGSize(width: 900, height: Theme.nowPlayingStripHeight)
        private static let compactSize = CGSize(width: 450, height: 145)

        // MARK: - Helpers

        private func makeNowPlayingVM() async throws -> NowPlayingViewModel {
            let db = try await Database(location: .inMemory)
            let engine = MockTransport()
            return NowPlayingViewModel(engine: engine, database: db)
        }

        private func makeLibraryVM() async throws -> LibraryViewModel {
            let db = try await Database(location: .inMemory)
            let engine = MockTransport()
            return LibraryViewModel(database: db, engine: engine)
        }

        private func makeMiniPlayerVM() async throws -> MiniPlayerViewModel {
            let np = try await makeNowPlayingVM()
            return MiniPlayerViewModel(nowPlaying: np)
        }

        // MARK: - NowPlayingStrip with increase-contrast

        @Test("NowPlayingStrip high contrast light mode")
        func stripHighContrastLight() async throws {
            let vm = try await makeNowPlayingVM()
            let vizVM = VisualizerViewModel(engine: AudioEngine())
            let view = NowPlayingStrip(vm: vm)
                .environmentObject(vizVM)
                .environment(DSPViewModel(engine: AudioEngine()))
                .environment(\.bocanHighContrast, true)
                .frame(width: Self.stripSize.width, height: Self.stripSize.height)
            assertSnapshot(
                of: host(view, size: Self.stripSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "strip-high-contrast-light"
            )
        }

        @Test("NowPlayingStrip high contrast dark mode")
        func stripHighContrastDark() async throws {
            let vm = try await makeNowPlayingVM()
            let vizVM = VisualizerViewModel(engine: AudioEngine())
            let view = NowPlayingStrip(vm: vm)
                .environmentObject(vizVM)
                .environment(DSPViewModel(engine: AudioEngine()))
                .environment(\.bocanHighContrast, true)
                .colorScheme(.dark)
                .frame(width: Self.stripSize.width, height: Self.stripSize.height)
            assertSnapshot(
                of: host(view, size: Self.stripSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "strip-high-contrast-dark"
            )
        }

        // MARK: - MiniPlayerCompact with increase-contrast

        @Test("MiniPlayerCompact high contrast light mode")
        func compactHighContrastLight() async throws {
            let miniVM = try await makeMiniPlayerVM()
            let libraryVM = try await makeLibraryVM()
            let view = MiniPlayerCompact(vm: miniVM)
                .environmentObject(libraryVM)
                .environment(\.bocanHighContrast, true)
                .environment(\.marqueeReduceMotion, true)
                .frame(width: Self.compactSize.width, height: Self.compactSize.height)
            assertSnapshot(
                of: host(view, size: Self.compactSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "compact-high-contrast-light"
            )
        }

        @Test("MiniPlayerCompact high contrast dark mode")
        func compactHighContrastDark() async throws {
            let miniVM = try await makeMiniPlayerVM()
            let libraryVM = try await makeLibraryVM()
            let view = MiniPlayerCompact(vm: miniVM)
                .environmentObject(libraryVM)
                .environment(\.bocanHighContrast, true)
                .environment(\.marqueeReduceMotion, true)
                .colorScheme(.dark)
                .frame(width: Self.compactSize.width, height: Self.compactSize.height)
            assertSnapshot(
                of: host(view, size: Self.compactSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "compact-high-contrast-dark"
            )
        }
    }
}

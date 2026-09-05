import AppKit
import AudioEngine
import Library
import Persistence
import SnapshotTesting
import SwiftUI
import Testing
@testable import UI

/// The three view models an ``ImmersiveView`` needs, built on one in-memory
/// database and one mock transport.
@MainActor
private struct ImmersiveSnapshotGraph {
    let library: LibraryViewModel
    let lyrics: LyricsViewModel
    let visualizer: VisualizerViewModel

    static func make() async throws -> Self {
        let db = try await Database(location: .inMemory)
        let engine = MockTransport()
        return Self(
            library: LibraryViewModel(database: db, engine: engine),
            lyrics: LyricsViewModel(service: LyricsService(database: db, fetcher: nil)),
            visualizer: VisualizerViewModel(engine: AudioEngine())
        )
    }

    func setTrack() {
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            fileURL: "file:///tmp/test.flac",
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "flac",
            duration: 300,
            title: "Here Comes the Sun",
            addedAt: now,
            updatedAt: now
        )
        self.library.nowPlaying.setCurrentTrack(track)
    }
}

extension UISnapshotTests {
    // MARK: - Immersive Mode Snapshots (ADR-089)

    /// The overlay forces a dark scheme, so light and dark should look the
    /// same apart from anything that escapes the forced environment; both
    /// are recorded to prove nothing inside goes invisible in either.
    @Suite("Immersive Mode Snapshots")
    @MainActor
    struct ImmersiveSnapshotTests {
        private let size = CGSize(width: 1200, height: 720)

        private func view(_ graph: ImmersiveSnapshotGraph) -> some View {
            ImmersiveView(
                library: graph.library,
                lyricsVM: graph.lyrics,
                visualizerVM: graph.visualizer
            ) {}
                .frame(width: self.size.width, height: self.size.height)
        }

        @Test("Immersive idle light")
        func idleLight() async throws {
            let graph = try await ImmersiveSnapshotGraph.make()
            assertSnapshot(
                of: host(self.view(graph), size: self.size),
                as: .image(precision: 0.95, perceptualPrecision: 0.98),
                named: "immersive-idle-light"
            )
        }

        @Test("Immersive idle dark")
        func idleDark() async throws {
            let graph = try await ImmersiveSnapshotGraph.make()
            assertSnapshot(
                of: host(self.view(graph).colorScheme(.dark), size: self.size),
                as: .image(precision: 0.95, perceptualPrecision: 0.98),
                named: "immersive-idle-dark"
            )
        }

        @Test("Immersive with track light")
        func withTrackLight() async throws {
            let graph = try await ImmersiveSnapshotGraph.make()
            graph.setTrack()
            assertSnapshot(
                of: host(self.view(graph), size: self.size),
                as: .image(precision: 0.95, perceptualPrecision: 0.98),
                named: "immersive-track-light"
            )
        }

        @Test("Immersive with track, increased contrast")
        func withTrackHighContrast() async throws {
            let graph = try await ImmersiveSnapshotGraph.make()
            graph.setTrack()
            assertSnapshot(
                of: host(self.view(graph).environment(\.bocanHighContrast, true), size: self.size),
                as: .image(precision: 0.95, perceptualPrecision: 0.98),
                named: "immersive-track-high-contrast"
            )
        }
    }
}

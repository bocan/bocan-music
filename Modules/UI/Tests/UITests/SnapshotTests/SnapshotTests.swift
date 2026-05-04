import Acoustics
import AppKit
import AudioEngine
import Foundation
import Library
import SnapshotTesting
import SwiftUI
import Testing
@testable import Persistence
@testable import UI

// MARK: - SnapshotTestHelpers

/// Wraps a SwiftUI view in an NSHostingView at the given size for NSView-based snapshot testing.
@MainActor
func host(_ view: some View, size: CGSize) -> NSView {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: size)
    return hosting
}

// MARK: - SnapshotTests

/// All snapshot suites are nested under a single .serialized parent so they run
/// sequentially, preventing concurrent @MainActor rendering races.
///
/// Snapshot tests are disabled on CI because pixel-level SwiftUI/AppKit
/// rendering differs subtly between developer Macs and GitHub-hosted runners
/// (font hinting, GPU, color profile), producing false positives even at 98%
/// precision. They remain a local visual-regression guardrail.
@Suite(
    "UI Snapshots",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Snapshot tests are local-only; rendering differs on CI runners."
    )
)
@MainActor
struct UISnapshotTests {
    @Suite("Sidebar Snapshots")
    @MainActor
    struct SidebarSnapshotTests {
        private func makeVM() async throws -> LibraryViewModel {
            let db = try await Database(location: .inMemory)
            let engine = MockTransport()
            return LibraryViewModel(database: db, engine: engine)
        }

        @Test("Sidebar light mode")
        func sidebarLight() async throws {
            let vm = try await makeVM()
            let view = Sidebar(vm: vm).frame(width: 220, height: 600)
            assertSnapshot(
                of: host(view, size: CGSize(width: 220, height: 600)),
                as: .image(precision: 0.98),
                named: "sidebar-light"
            )
        }

        @Test("Sidebar dark mode")
        func sidebarDark() async throws {
            let vm = try await makeVM()
            let view = Sidebar(vm: vm).frame(width: 220, height: 600).colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: CGSize(width: 220, height: 600)),
                as: .image(precision: 0.98),
                named: "sidebar-dark"
            )
        }
    }

    // MARK: - NowPlayingStripSnapshotTests

    @Suite("NowPlayingStrip Snapshots")
    @MainActor
    struct NowPlayingStripSnapshotTests {
        private func makeNowPlayingVM() async throws -> NowPlayingViewModel {
            let db = try await Database(location: .inMemory)
            let engine = MockTransport()
            return NowPlayingViewModel(engine: engine, database: db)
        }

        private func makeVisualizerVM() -> VisualizerViewModel {
            VisualizerViewModel(engine: AudioEngine())
        }

        @Test("Strip idle light mode")
        func stripIdleLight() async throws {
            let vm = try await makeNowPlayingVM()
            let vizVM = self.makeVisualizerVM()
            let size = CGSize(width: 900, height: Theme.nowPlayingStripHeight)
            let view = NowPlayingStrip(vm: vm)
                .environmentObject(vizVM)
                .frame(width: size.width, height: size.height)
            assertSnapshot(of: host(view, size: size), as: .image(precision: 0.98), named: "strip-idle-light")
        }

        @Test("Strip idle dark mode")
        func stripIdleDark() async throws {
            let vm = try await makeNowPlayingVM()
            let vizVM = self.makeVisualizerVM()
            let size = CGSize(width: 900, height: Theme.nowPlayingStripHeight)
            let view = NowPlayingStrip(vm: vm)
                .environmentObject(vizVM)
                .frame(width: size.width, height: size.height)
                .colorScheme(.dark)
            assertSnapshot(of: host(view, size: size), as: .image(precision: 0.98), named: "strip-idle-dark")
        }

        @Test("Strip with track light mode")
        func stripWithTrackLight() async throws {
            let db = try await Database(location: .inMemory)
            let engine = MockTransport()
            let vm = NowPlayingViewModel(engine: engine, database: db)
            let vizVM = self.makeVisualizerVM()
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
            vm.setCurrentTrack(track)
            let size = CGSize(width: 900, height: Theme.nowPlayingStripHeight)
            let view = NowPlayingStrip(vm: vm)
                .environmentObject(vizVM)
                .frame(width: size.width, height: size.height)
            assertSnapshot(of: host(view, size: size), as: .image(precision: 0.98), named: "strip-with-track-light")
        }
    }

    // MARK: - TracksViewSnapshotTests

    @Suite("TracksView Snapshots")
    @MainActor
    struct TracksViewSnapshotTests {
        private func makeVM(db: Database) -> TracksViewModel {
            TracksViewModel(
                repository: TrackRepository(database: db),
                artistRepository: ArtistRepository(database: db),
                albumRepository: AlbumRepository(database: db)
            )
        }

        private func makeLibraryVM(db: Database) -> LibraryViewModel {
            LibraryViewModel(database: db, engine: MockTransport())
        }

        @Test("TracksView empty state light")
        func emptyLight() async throws {
            let db = try await Database(location: .inMemory)
            let view = TracksView(vm: makeVM(db: db), library: makeLibraryVM(db: db))
                .frame(width: 900, height: 500)
            assertSnapshot(
                of: host(view, size: CGSize(width: 900, height: 500)),
                as: .image(precision: 0.98),
                named: "tracks-empty-light"
            )
        }

        @Test("TracksView empty state dark")
        func emptyDark() async throws {
            let db = try await Database(location: .inMemory)
            let view = TracksView(vm: makeVM(db: db), library: makeLibraryVM(db: db))
                .frame(width: 900, height: 500)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: CGSize(width: 900, height: 500)),
                as: .image(precision: 0.98),
                named: "tracks-empty-dark"
            )
        }
    }

    // MARK: - AlbumsGridSnapshotTests

    @Suite("AlbumsGrid Snapshots")
    @MainActor
    struct AlbumsGridSnapshotTests {
        @Test("AlbumsGrid empty state light")
        func emptyLight() async throws {
            let db = try await Database(location: .inMemory)
            let albumsVM = AlbumsViewModel(repository: AlbumRepository(database: db))
            let libraryVM = LibraryViewModel(database: db, engine: MockTransport())
            let view = AlbumsGridView(vm: albumsVM, library: libraryVM)
                .frame(width: 900, height: 600)
            assertSnapshot(
                of: host(view, size: CGSize(width: 900, height: 600)),
                as: .image(precision: 0.98),
                named: "albums-empty-light"
            )
        }

        @Test("AlbumsGrid empty state dark")
        func emptyDark() async throws {
            let db = try await Database(location: .inMemory)
            let albumsVM = AlbumsViewModel(repository: AlbumRepository(database: db))
            let libraryVM = LibraryViewModel(database: db, engine: MockTransport())
            let view = AlbumsGridView(vm: albumsVM, library: libraryVM)
                .frame(width: 900, height: 600)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: CGSize(width: 900, height: 600)),
                as: .image(precision: 0.98),
                named: "albums-empty-dark"
            )
        }
    }

    // MARK: - VisualizerSnapshotTests

    // Note: Metal render paths (FluidMetal) are exempt from snapshot testing
    // because MTKView requires a GPU, which is unavailable in headless environments.

    @Suite("Visualizer Snapshots")
    @MainActor
    struct VisualizerSnapshotTests {
        private static let syntheticAnalysis: Analysis = {
            // Simulate a mid-heavy music signal for stable snapshots.
            var bands = [Float](repeating: 0, count: FFTAnalyzer.bandCount)
            for i in 0 ..< bands.count {
                let t = Float(i) / Float(bands.count)
                bands[i] = sin(t * .pi) * 0.8 // hump shape
            }
            return Analysis(bands: bands, rms: 0.6, peak: 0.9)
        }()

        @Test("SpectrumBars light mode")
        func spectrumBarsLight() {
            let viz = VisualizerViewModel(engine: AudioEngine())
            viz.mode = .spectrumBars
            viz.palette = .spectrum
            let view = VisualizerHost(vm: viz)
                .frame(width: 400, height: 200)
            assertSnapshot(
                of: host(view, size: CGSize(width: 400, height: 200)),
                as: .image(precision: 0.95),
                named: "viz-spectrum-bars-light"
            )
        }

        @Test("SpectrumBars dark mode")
        func spectrumBarsDark() {
            let viz = VisualizerViewModel(engine: AudioEngine())
            viz.mode = .spectrumBars
            viz.palette = .spectrum
            let view = VisualizerHost(vm: viz)
                .frame(width: 400, height: 200)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: CGSize(width: 400, height: 200)),
                as: .image(precision: 0.95),
                named: "viz-spectrum-bars-dark"
            )
        }

        @Test("Oscilloscope light mode")
        func oscilloscopeLight() {
            let viz = VisualizerViewModel(engine: AudioEngine())
            viz.mode = .oscilloscope
            viz.palette = .accent
            let view = VisualizerHost(vm: viz)
                .frame(width: 400, height: 200)
            assertSnapshot(
                of: host(view, size: CGSize(width: 400, height: 200)),
                as: .image(precision: 0.95),
                named: "viz-oscilloscope-light"
            )
        }

        @Test("Oscilloscope dark mode")
        func oscilloscopeDark() {
            let viz = VisualizerViewModel(engine: AudioEngine())
            viz.mode = .oscilloscope
            viz.palette = .mono
            let view = VisualizerHost(vm: viz)
                .frame(width: 400, height: 200)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: CGSize(width: 400, height: 200)),
                as: .image(precision: 0.95),
                named: "viz-oscilloscope-dark"
            )
        }
    }

    // MARK: - PlaylistFolderView Snapshots

    @Suite("PlaylistFolderView Snapshots")
    @MainActor
    struct PlaylistFolderViewSnapshotTests {
        private func makeVM() async throws -> LibraryViewModel {
            let db = try await Database(location: .inMemory)
            let engine = MockTransport()
            return LibraryViewModel(database: db, engine: engine)
        }

        private func makeChildNodes() -> [PlaylistNode] {
            [
                PlaylistNode(
                    id: 2,
                    name: "Chill Mix",
                    kind: .manual,
                    parentID: 1,
                    coverArtPath: nil,
                    accentHex: nil,
                    trackCount: 12,
                    totalDuration: 2880,
                    sortOrder: 0,
                    children: []
                ),
                PlaylistNode(
                    id: 3,
                    name: "Most Played",
                    kind: .smart,
                    parentID: 1,
                    coverArtPath: nil,
                    accentHex: nil,
                    trackCount: 7,
                    totalDuration: 1680,
                    sortOrder: 1,
                    children: []
                ),
                PlaylistNode(
                    id: 4,
                    name: "Subfolder",
                    kind: .folder,
                    parentID: 1,
                    coverArtPath: nil,
                    accentHex: nil,
                    trackCount: 0,
                    totalDuration: 0,
                    sortOrder: 2,
                    children: []
                ),
            ]
        }

        private func makeNode(withChildren: Bool) -> PlaylistNode {
            PlaylistNode(
                id: 1,
                name: "My Folder",
                kind: .folder,
                parentID: nil,
                coverArtPath: nil,
                accentHex: nil,
                trackCount: 0,
                totalDuration: 0,
                sortOrder: 0,
                children: withChildren ? self.makeChildNodes() : []
            )
        }

        @Test("PlaylistFolderView with children light mode")
        func folderWithChildrenLight() async throws {
            let vm = try await makeVM()
            let view = PlaylistFolderView(node: makeNode(withChildren: true), library: vm)
                .frame(width: 600, height: 400)
            assertSnapshot(
                of: host(view, size: CGSize(width: 600, height: 400)),
                as: .image(precision: 0.98),
                named: "playlist-folder-children-light"
            )
        }

        @Test("PlaylistFolderView with children dark mode")
        func folderWithChildrenDark() async throws {
            let vm = try await makeVM()
            let view = PlaylistFolderView(node: makeNode(withChildren: true), library: vm)
                .frame(width: 600, height: 400)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: CGSize(width: 600, height: 400)),
                as: .image(precision: 0.98),
                named: "playlist-folder-children-dark"
            )
        }

        @Test("PlaylistFolderView empty light mode")
        func folderEmptyLight() async throws {
            let vm = try await makeVM()
            let view = PlaylistFolderView(node: makeNode(withChildren: false), library: vm)
                .frame(width: 600, height: 400)
            assertSnapshot(
                of: host(view, size: CGSize(width: 600, height: 400)),
                as: .image(precision: 0.98),
                named: "playlist-folder-empty-light"
            )
        }

        @Test("PlaylistFolderView empty dark mode")
        func folderEmptyDark() async throws {
            let vm = try await makeVM()
            let view = PlaylistFolderView(node: makeNode(withChildren: false), library: vm)
                .frame(width: 600, height: 400)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: CGSize(width: 600, height: 400)),
                as: .image(precision: 0.98),
                named: "playlist-folder-empty-dark"
            )
        }
    }
} // end UISnapshotTests

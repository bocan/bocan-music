import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import Persistence
@testable import UI

// MARK: - SnapshotTestHelpers

/// Wraps a SwiftUI view in an NSHostingView at the given size for NSView-based snapshot testing.
@MainActor
private func host(_ view: some View, size: CGSize) -> NSView {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: size)
    return hosting
}

// MARK: - SnapshotTests

/// All snapshot suites are nested under a single .serialized parent so they run
/// sequentially, preventing concurrent @MainActor rendering races.
@Suite("UI Snapshots", .serialized)
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
        private func makeVM() async throws -> NowPlayingViewModel {
            let db = try await Database(location: .inMemory)
            let engine = MockTransport()
            return NowPlayingViewModel(engine: engine, database: db)
        }

        @Test("Strip idle light mode")
        func stripIdleLight() async throws {
            let vm = try await makeVM()
            let size = CGSize(width: 900, height: Theme.nowPlayingStripHeight)
            let view = NowPlayingStrip(vm: vm).frame(width: size.width, height: size.height)
            assertSnapshot(of: host(view, size: size), as: .image(precision: 0.98), named: "strip-idle-light")
        }

        @Test("Strip idle dark mode")
        func stripIdleDark() async throws {
            let vm = try await makeVM()
            let size = CGSize(width: 900, height: Theme.nowPlayingStripHeight)
            let view = NowPlayingStrip(vm: vm)
                .frame(width: size.width, height: size.height)
                .colorScheme(.dark)
            assertSnapshot(of: host(view, size: size), as: .image(precision: 0.98), named: "strip-idle-dark")
        }

        @Test("Strip with track light mode")
        func stripWithTrackLight() async throws {
            let db = try await Database(location: .inMemory)
            let engine = MockTransport()
            let vm = NowPlayingViewModel(engine: engine, database: db)
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
            let view = NowPlayingStrip(vm: vm).frame(width: size.width, height: size.height)
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
} // end UISnapshotTests

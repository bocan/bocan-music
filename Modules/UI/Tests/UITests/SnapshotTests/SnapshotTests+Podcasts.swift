import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import Persistence
@testable import UI

extension UISnapshotTests {
    // MARK: - PodcastsHomeView Snapshots

    @Suite("Podcasts Snapshots")
    @MainActor
    struct PodcastsSnapshotTests {
        private let size = CGSize(width: 700, height: 480)

        private func makeVM() -> PodcastsViewModel {
            PodcastsViewModel(library: nil, actions: nil)
        }

        private func makeLibVM() async throws -> LibraryViewModel {
            let db = try await Database(location: .inMemory)
            let engine = MockTransport()
            return LibraryViewModel(database: db, engine: engine)
        }

        @Test("PodcastsHomeView empty state light mode")
        func emptyStateLight() async throws {
            let libVM = try await makeLibVM()
            let vm = self.makeVM()
            let view = PodcastsHomeView(vm: vm, library: libVM)
                .frame(width: 700, height: 480)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "podcasts-home-empty-light"
            )
        }

        @Test("PodcastsHomeView empty state dark mode")
        func emptyStateDark() async throws {
            let libVM = try await makeLibVM()
            let vm = self.makeVM()
            let view = PodcastsHomeView(vm: vm, library: libVM)
                .frame(width: 700, height: 480)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "podcasts-home-empty-dark"
            )
        }
    }
}

import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import Persistence
@testable import UI

extension UISnapshotTests {
    // MARK: - RadioView Snapshots

    @Suite("Radio Snapshots")
    @MainActor
    struct RadioSnapshotTests {
        private let size = CGSize(width: 700, height: 480)

        private func makeLibVM() async throws -> LibraryViewModel {
            let db = try await Database(location: .inMemory)
            let engine = MockTransport()
            return LibraryViewModel(database: db, engine: engine)
        }

        @Test("RadioView empty state light mode")
        func emptyStateLight() async throws {
            let libVM = try await makeLibVM()
            let view = RadioView(library: libVM, searchQuery: "")
                .frame(width: 700, height: 480)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "radio-empty-light"
            )
        }

        @Test("RadioView empty state dark mode")
        func emptyStateDark() async throws {
            let libVM = try await makeLibVM()
            let view = RadioView(library: libVM, searchQuery: "")
                .frame(width: 700, height: 480)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "radio-empty-dark"
            )
        }
    }
}

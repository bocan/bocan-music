import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import UI

extension UISnapshotTests {
    // MARK: - LoadingState Snapshots

    @Suite("LoadingState Snapshots")
    @MainActor
    struct LoadingStateSnapshotTests {
        private let size = CGSize(width: 600, height: 400)

        @Test("LoadingState default light")
        func defaultLight() {
            let view = LoadingState()
                .frame(width: 600, height: 400)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "loading-state-default-light"
            )
        }

        @Test("LoadingState default dark")
        func defaultDark() {
            let view = LoadingState()
                .frame(width: 600, height: 400)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "loading-state-default-dark"
            )
        }

        @Test("LoadingState with message light")
        func withMessageLight() {
            let view = LoadingState(
                title: "Scanning library…",
                message: "Reading file metadata from your music folders."
            )
            .frame(width: 600, height: 400)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "loading-state-message-light"
            )
        }

        @Test("LoadingState with message dark")
        func withMessageDark() {
            let view = LoadingState(
                title: "Scanning library…",
                message: "Reading file metadata from your music folders."
            )
            .frame(width: 600, height: 400)
            .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "loading-state-message-dark"
            )
        }
    }

    // MARK: - ErrorState Snapshots

    @Suite("ErrorState Snapshots")
    @MainActor
    struct ErrorStateSnapshotTests {
        private let size = CGSize(width: 600, height: 400)

        @Test("ErrorState no action light")
        func noActionLight() {
            let view = ErrorState(
                title: "Could Not Load",
                message: "The playlist could not be read from the database."
            )
            .frame(width: 600, height: 400)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "error-state-no-action-light"
            )
        }

        @Test("ErrorState no action dark")
        func noActionDark() {
            let view = ErrorState(
                title: "Could Not Load",
                message: "The playlist could not be read from the database."
            )
            .frame(width: 600, height: 400)
            .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "error-state-no-action-dark"
            )
        }

        @Test("ErrorState with retry light")
        func withRetryLight() {
            let view = ErrorState(
                title: "Scan Failed",
                message: "The library folder could not be read. Check permissions in System Settings.",
                actionLabel: "Try Again"
            ) {}
                .frame(width: 600, height: 400)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "error-state-retry-light"
            )
        }

        @Test("ErrorState with retry dark")
        func withRetryDark() {
            let view = ErrorState(
                title: "Scan Failed",
                message: "The library folder could not be read. Check permissions in System Settings.",
                actionLabel: "Try Again"
            ) {}
                .frame(width: 600, height: 400)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "error-state-retry-dark"
            )
        }
    }
}

import Acoustics
import Foundation
import Library
import SnapshotTesting
import SwiftUI
import Testing
@testable import Persistence
@testable import UI

extension UISnapshotTests {
    // MARK: - IdentifyTrackSheet Snapshots

    @Suite("IdentifyTrackSheet Snapshots")
    @MainActor
    struct IdentifyTrackSheetSnapshotTests {
        private static let sheetSize = CGSize(width: 560, height: 380)

        private func makeVM(phase: IdentifyTrackViewModel.Phase) async throws -> IdentifyTrackViewModel {
            let db = try await Database(location: .inMemory)
            let fpService = FingerprintService(
                database: db,
                fpcalcURL: URL(fileURLWithPath: "/nonexistent/fpcalc"),
                acoustIDAPIKey: "snapshot-test"
            )
            let queue = FingerprintQueue(service: fpService)
            let editService = try MetadataEditService(database: db)
            let now = Int64(Date().timeIntervalSince1970)
            let track = Track(
                fileURL: "file:///tmp/come-together.flac",
                duration: 259,
                title: "Come Together",
                addedAt: now,
                updatedAt: now
            )
            let vm = IdentifyTrackViewModel(track: track, queue: queue, editService: editService)
            vm.overridePhase(phase)
            return vm
        }

        private static let sampleCandidate = IdentificationCandidate(
            id: "2dd41a10-3b4c-4bcd-87dc-c49dda6b5660",
            score: 0.947,
            mbRecordingID: "f76e9be1-bd30-4b26-b0a6-1b8e9c70e4df",
            title: "Come Together",
            artist: "The Beatles",
            album: "Abbey Road",
            year: 1969,
            label: "Apple Records"
        )

        // MARK: - Fingerprinting state

        @Test("IdentifyTrackSheet fingerprinting state light")
        func fingerprintingLight() async throws {
            let vm = try await makeVM(phase: .fingerprinting)
            let view = IdentifyTrackSheet(vm: vm)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98),
                named: "identify-fingerprinting-light"
            )
        }

        @Test("IdentifyTrackSheet fingerprinting state dark")
        func fingerprintingDark() async throws {
            let vm = try await makeVM(phase: .fingerprinting)
            let view = IdentifyTrackSheet(vm: vm)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98),
                named: "identify-fingerprinting-dark"
            )
        }

        // MARK: - Looking up state

        @Test("IdentifyTrackSheet looking-up state light")
        func lookingUpLight() async throws {
            let vm = try await makeVM(phase: .lookingUp)
            let view = IdentifyTrackSheet(vm: vm)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98),
                named: "identify-lookingup-light"
            )
        }

        @Test("IdentifyTrackSheet looking-up state dark")
        func lookingUpDark() async throws {
            let vm = try await makeVM(phase: .lookingUp)
            let view = IdentifyTrackSheet(vm: vm)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98),
                named: "identify-lookingup-dark"
            )
        }

        // MARK: - Results state

        @Test("IdentifyTrackSheet results state light")
        func resultsLight() async throws {
            let vm = try await makeVM(phase: .results([Self.sampleCandidate]))
            let view = IdentifyTrackSheet(vm: vm)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98),
                named: "identify-results-light"
            )
        }

        @Test("IdentifyTrackSheet results state dark")
        func resultsDark() async throws {
            let vm = try await makeVM(phase: .results([Self.sampleCandidate]))
            let view = IdentifyTrackSheet(vm: vm)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98),
                named: "identify-results-dark"
            )
        }

        // MARK: - No match state

        @Test("IdentifyTrackSheet no-match state light")
        func noMatchLight() async throws {
            let vm = try await makeVM(phase: .noMatch)
            let view = IdentifyTrackSheet(vm: vm)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98),
                named: "identify-nomatch-light"
            )
        }

        @Test("IdentifyTrackSheet no-match state dark")
        func noMatchDark() async throws {
            let vm = try await makeVM(phase: .noMatch)
            let view = IdentifyTrackSheet(vm: vm)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98),
                named: "identify-nomatch-dark"
            )
        }

        // MARK: - Error state

        @Test("IdentifyTrackSheet error state light")
        func errorLight() async throws {
            let vm = try await makeVM(phase: .error("fpcalc exited with code 1"))
            let view = IdentifyTrackSheet(vm: vm)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98),
                named: "identify-error-light"
            )
        }

        @Test("IdentifyTrackSheet error state dark")
        func errorDark() async throws {
            let vm = try await makeVM(phase: .error("fpcalc exited with code 1"))
            let view = IdentifyTrackSheet(vm: vm)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98),
                named: "identify-error-dark"
            )
        }
    }
}

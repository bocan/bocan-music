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
        private static let sheetSize = CGSize(width: 680, height: 480)

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

        private static let sampleReleases = [
            ReleaseOption(
                id: "9e53c190-5621-3848-8ae4-39ad9f7d9ace",
                title: "Abbey Road",
                date: "1969-09-26",
                year: 1969,
                country: "GB",
                status: "Official",
                albumArtist: "The Beatles",
                albumArtistMBID: "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
                releaseGroupID: "9162580e-5df4-32de-80cc-f45a8d8a9b1d",
                trackNumber: 1,
                discNumber: 1,
                trackTotal: 17,
                mediaFormat: "12\" Vinyl"
            ),
            ReleaseOption(
                id: "d5f9f7a2-0000-0000-0000-000000000001",
                title: "Abbey Road (2009 Remaster)",
                date: "2009-09-09",
                year: 2009,
                country: "XW",
                status: "Official",
                trackNumber: 1,
                discNumber: 1,
                trackTotal: 17,
                mediaFormat: "CD"
            ),
            ReleaseOption(
                id: "d5f9f7a2-0000-0000-0000-000000000002",
                title: "1967-1970",
                date: "1973-04-02",
                year: 1973,
                country: "US",
                status: "Promotion",
                trackNumber: 3,
                discNumber: 2,
                trackTotal: 14,
                mediaFormat: "12\" Vinyl"
            ),
        ]

        private static let sampleCandidate = IdentificationCandidate(
            id: "2dd41a10-3b4c-4bcd-87dc-c49dda6b5660",
            score: 0.947,
            mbRecordingID: "f76e9be1-bd30-4b26-b0a6-1b8e9c70e4df",
            title: "Come Together",
            artist: "The Beatles",
            album: "Abbey Road",
            year: 1969,
            label: "Apple Records",
            isrcs: ["GBAYE0601696"],
            releases: sampleReleases
        )

        // MARK: - Fingerprinting state

        @Test("IdentifyTrackSheet fingerprinting state light")
        func fingerprintingLight() async throws {
            let vm = try await makeVM(phase: .fingerprinting)
            let view = IdentifyTrackSheet(vm: vm)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
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
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
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
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
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
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
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
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
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
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "identify-results-dark"
            )
        }

        // MARK: - Expanded picker states (hosted directly; expansion is view state)

        private static let sampleCurrentValues = CurrentTagValues(
            title: "Come Togther",
            artist: "Beatles",
            year: 1969
        )

        private func expandedPicker(showAdvanced: Bool) -> some View {
            CandidatePickerView(
                candidates: [Self.sampleCandidate],
                currentValues: Self.sampleCurrentValues,
                onApply: { _, _, _ in },
                onSkip: {},
                initiallyExpanded: Self.sampleCandidate.id,
                initiallyShowAdvanced: showAdvanced
            )
        }

        @Test("Candidate picker expanded with release picker light")
        func pickerExpandedLight() {
            let view = self.expandedPicker(showAdvanced: false)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "identify-picker-expanded-light"
            )
        }

        @Test("Candidate picker expanded with release picker dark")
        func pickerExpandedDark() {
            let view = self.expandedPicker(showAdvanced: false)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "identify-picker-expanded-dark"
            )
        }

        @Test("Candidate picker with advanced fields shown light")
        func pickerAdvancedLight() {
            let view = self.expandedPicker(showAdvanced: true)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "identify-picker-advanced-light"
            )
        }

        @Test("Candidate picker with advanced fields shown dark")
        func pickerAdvancedDark() {
            let view = self.expandedPicker(showAdvanced: true)
                .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
                .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: Self.sheetSize),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "identify-picker-advanced-dark"
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
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
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
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
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
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
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
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "identify-error-dark"
            )
        }
    }
}

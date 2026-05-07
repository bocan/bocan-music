import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - QuitGuardStateTests

/// Validates the properties that `AppDelegate.applicationShouldTerminate` reads
/// to decide whether to show a quit confirmation.
///
/// `AppDelegate` lives in the app target (no BUNDLE_LOADER), so we cannot
/// instantiate it in unit tests.  Instead we verify the view-model state that
/// drives the guard: the guard fires when `libraryViewModel.isScanning`,
/// `libraryViewModel.isInitialScan`, or `dspViewModel.isAnalyzing` is true.
@Suite("Quit-guard state (applicationShouldTerminate inputs)")
@MainActor
struct QuitGuardStateTests {
    // MARK: - LibraryViewModel scanning state

    private func makeLibraryVM() async throws -> LibraryViewModel {
        let db = try await Database(location: .inMemory)
        return LibraryViewModel(database: db, engine: MockTransport())
    }

    @Test("isScanning starts false — normal quit needs no confirmation")
    func isScanningStartsFalse() async throws {
        let vm = try await self.makeLibraryVM()
        #expect(vm.isScanning == false)
    }

    @Test("isInitialScan starts false — first-load guard starts inactive")
    func isInitialScanStartsFalse() async throws {
        let vm = try await self.makeLibraryVM()
        #expect(vm.isInitialScan == false)
    }

    @Test("isScanning true triggers the scan guard")
    func isScanningTrueTriggersGuard() async throws {
        let vm = try await self.makeLibraryVM()
        vm.isScanning = true
        // AppDelegate guard condition: isScanning || isInitialScan || isAnalyzing
        let guardActive = vm.isScanning || vm.isInitialScan
        #expect(guardActive == true)
    }

    @Test("isInitialScan true triggers the first-load guard")
    func isInitialScanTrueTriggersGuard() async throws {
        let vm = try await self.makeLibraryVM()
        vm.isInitialScan = true
        // First-load scenario: guard fires even if the generic isScanning flag
        // is checked by itself — isInitialScan implies a scan is active.
        let guardActive = vm.isScanning || vm.isInitialScan
        #expect(guardActive == true)
    }

    @Test("Both scan flags false — no guard trigger")
    func neitherScanFlagActive() async throws {
        let vm = try await self.makeLibraryVM()
        vm.isScanning = false
        vm.isInitialScan = false
        let guardActive = vm.isScanning || vm.isInitialScan
        #expect(guardActive == false)
    }

    @Test("cancelScan resets both flags to false")
    func cancelScanResetsBothFlags() async throws {
        let vm = try await self.makeLibraryVM()
        vm.isScanning = true
        vm.isInitialScan = true
        vm.cancelScan()
        #expect(vm.isScanning == false)
        #expect(vm.isInitialScan == false)
    }

    // MARK: - DSPViewModel analysing state

    @Test("isAnalyzing starts false — RG guard starts inactive")
    func isAnalyzingStartsFalse() {
        let vm = DSPViewModel(engine: .init())
        #expect(vm.isAnalyzing == false)
    }
}

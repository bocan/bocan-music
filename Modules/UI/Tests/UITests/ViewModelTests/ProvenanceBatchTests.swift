import AVFoundation
import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - ProvenanceBatchTests

/// Functional coverage for the phase 24-3 transcode-detection batch on
/// ``LibraryViewModel``: the zero-work toast, the failure path, a real
/// verdict landing in the database, and the re-run guards.
@Suite("Provenance batch")
@MainActor
struct ProvenanceBatchTests {
    // MARK: - Helpers

    private func makeVM() async throws -> LibraryViewModel {
        let db = try await Database(location: .inMemory)
        return LibraryViewModel(database: db, engine: MockTransport())
    }

    private func seedLosslessTrack(
        _ vm: LibraryViewModel,
        fileURL: String,
        bookmark: Data
    ) async throws -> Int64 {
        var track = Track(
            fileURL: fileURL,
            fileMtime: 100,
            fileFormat: "flac",
            duration: 1,
            addedAt: 0,
            updatedAt: 0
        )
        track.isLossless = true
        track.fileBookmark = bookmark
        return try await TrackRepository(database: vm.database).insert(track)
    }

    /// Two seconds of silence as a mono Float32 WAV: enough PCM for the
    /// analyzer to produce a (clean) verdict without any checked-in fixture.
    private static func writeSilentWAV(to url: URL) throws {
        let sampleRate = 44100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(sampleRate * 2)
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw URLError(.cannotCreateFile)
        }
        buffer.frameLength = frames // channel data is zero-initialised
        try file.write(from: buffer)
    }

    // MARK: - Tests

    @Test("An empty library toasts instead of showing progress")
    func emptyLibraryToasts() async throws {
        let vm = try await self.makeVM()
        await vm.analyseProvenance()
        #expect(vm.provenanceProgress == nil)
        #expect(vm.toast != nil)
    }

    @Test("An unreadable file counts as failed and the banner completes")
    func unreadableFileFails() async throws {
        let vm = try await self.makeVM()
        _ = try await self.seedLosslessTrack(
            vm,
            fileURL: "file:///tmp/provenance-missing.flac",
            bookmark: Data([1, 2, 3])
        )
        await vm.analyseProvenance()
        let progress = try #require(vm.provenanceProgress)
        #expect(progress.isComplete)
        #expect(progress.total == 1)
        #expect(progress.failed == 1)
        #expect(progress.suspected == 0)
        #expect(vm.toast != nil)
    }

    @Test("A decodable file gets its verdict written and leaves the queue")
    func decodableFileGetsVerdict() async throws {
        let vm = try await self.makeVM()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-batch-\(UUID().uuidString).wav")
        try Self.writeSilentWAV(to: url)
        let bookmark = try BookmarkBlob(url: url)
        let id = try await self.seedLosslessTrack(vm, fileURL: url.absoluteString, bookmark: bookmark.data)

        await vm.analyseProvenance()

        let progress = try #require(vm.provenanceProgress)
        #expect(progress.isComplete)
        #expect(progress.failed == 0)
        let repo = TrackRepository(database: vm.database)
        let track = try await repo.fetch(id: id)
        #expect(track.provenanceSuspected == false)
        #expect(track.provenanceAnalysedAt != nil)
        #expect(try await repo.countNeedingProvenance() == 0)

        try FileManager.default.removeItem(at: url)
    }

    @Test("A second start no-ops mid-run; a stale completed banner clears")
    func rerunGuards() async throws {
        let vm = try await self.makeVM()
        let running = ProvenanceBatchProgress(done: 1, total: 2, failed: 0, suspected: 0)
        vm.provenanceProgress = running
        await vm.analyseProvenance()
        #expect(vm.provenanceProgress == running, "a second run must not disturb one in flight")

        vm.provenanceProgress = ProvenanceBatchProgress(done: 2, total: 2, failed: 1, suspected: 1)
        vm.startProvenanceAnalysis()
        _ = await vm.provenanceTask?.value
        // The fresh run (empty library) ends bannerless with a toast.
        #expect(vm.provenanceProgress == nil)
        #expect(vm.toast != nil)
    }

    @Test("A menu start while already running toasts where to watch instead of doing nothing")
    func alreadyRunningAnnounces() async throws {
        let vm = try await self.makeVM()
        let running = ProvenanceBatchProgress(done: 1, total: 5, failed: 0, suspected: 0)
        vm.provenanceProgress = running
        vm.startProvenanceAnalysis()
        #expect(vm.provenanceProgress == running, "the running batch must be left alone")
        let toast = try #require(vm.toast)
        #expect(toast.text.contains("Library Summary"), "the toast must say where to watch")
    }

    @Test("Menu starts announce where to watch; the pane button stays quiet")
    func startAnnouncementConvention() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/ViewModels/LibraryViewModel+Provenance.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("Watch progress in Tools → Library Summary → Audio Quality"),
            "starting a run with announce must toast where the progress lives"
        )
        #expect(
            source.contains("already running. See Tools → Library Summary → Audio Quality"),
            "a start while running must point at the live progress instead of silently no-oping"
        )
    }

    @Test("Progress arithmetic")
    func progressArithmetic() {
        let running = ProvenanceBatchProgress(done: 3, total: 10, failed: 1, suspected: 2)
        #expect(!running.isComplete)
        #expect(running.succeeded == 2)
        let finished = ProvenanceBatchProgress(done: 10, total: 10, failed: 0, suspected: 4)
        #expect(finished.isComplete)
    }
}
